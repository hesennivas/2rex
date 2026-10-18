import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from sources.herdr import Error, import_workspaces, main, normalize, normalize_tree, panes_in, remap, rex_layout
from rex_common import atomic_json


def fixture(cwd="/tmp"):
    return {"version": 3, "workspaces": [{"id": "w1", "custom_name": "A & B", "identity_cwd": cwd,
        "active_tab": 0, "tabs": [{"custom_name": "dev", "focused": 3, "zoomed": False,
         "layout": {"Split": {"direction": "Horizontal", "ratio": .3, "first": {"Pane": 1},
            "second": {"Split": {"direction": "Vertical", "ratio": .65,
                        "first": {"Pane": 2}, "second": {"Pane": 3}}}}},
         "panes": {str(i): {"cwd": cwd, "label": f"pane {i}", "launch_argv": ["rm", "-rf", "/"]} for i in (1, 2, 3)}}]}]}


class ParserTests(unittest.TestCase):
    def test_saved_asymmetry_and_argv_ignored(self):
        w = normalize(fixture(), "default")[0]
        tree = w["tabs"][0]["tree"]
        self.assertEqual([p["id"] for p in panes_in(tree)], ["1", "2", "3"])
        out = rex_layout(tree)["split"]
        self.assertEqual((out["direction"], out["ratio"]), ("horizontal", .3))
        self.assertEqual(out["after"]["split"]["direction"], "vertical")
        self.assertNotIn('command', json.dumps(out))

    def test_live_portable_tree(self):
        t = {"type": "split", "direction": "down", "ratio": .2,
             "first": {"type": "pane", "pane_id": "w1:p1", "cwd": "/tmp"},
             "second": {"type": "pane", "pane_id": "w1:p2", "cwd": "/tmp"}}
        self.assertEqual(rex_layout(normalize_tree(t))["split"]["ratio"], .2)

    def test_bad_trees_and_versions(self):
        for ratio in (-1, 0, 1, True, float('nan'), "0.5"):
            src = fixture()
            src["workspaces"][0]["tabs"][0]["layout"]["Split"]["ratio"] = ratio
            with self.assertRaises(Error):
                normalize(src, "x")
        with self.assertRaises(Error):
            normalize({"version": 99}, "x")
        src = fixture()
        src["workspaces"][0]["tabs"][0]["panes"].pop("2")
        with self.assertRaises(Error):
            normalize(src, "x")

    def test_paths_spaces_unicode_and_prefix_boundaries(self):
        with tempfile.TemporaryDirectory(prefix="Rex 你好 ' ") as tmp:
            (Path(tmp)/"app").mkdir()
            self.assertEqual(remap("/remote/app", [("/remote", tmp)]), str(Path(tmp)/"app"))
            self.assertEqual(remap(tmp, []), tmp)
            with self.assertRaises(Error):
                remap("/remote-other", [("/remote", tmp)])

    def test_agent_state_is_not_carried(self):
        live = {"format": "herdr-live-v1", "snapshot": {
            "workspaces": [{"workspace_id": "w1", "label": "api", "active_tab_id": "t1"}],
            "tabs": [{"tab_id": "t1", "workspace_id": "w1", "label": "dev"}],
            "panes": [{"pane_id": "w1:p1", "agent": "claude",
                       "agent_session": {"agent": "claude", "kind": "id", "value": "x"}}]},
            "exports": {"t1": {"root": {"type": "pane", "pane_id": "w1:p1", "cwd": "/tmp", "label": "claude"}}}}
        pane = normalize(live, "default")[0]["tabs"][0]["tree"]
        self.assertEqual(set(pane), {"type", "id", "label", "cwd"})
        self.assertEqual(rex_layout(pane), {"block": {"flavor": "com.superlogical.terminal.shell",
                                                      "options": {"cwd": "/tmp"}}})

    def test_unnamed_panes_get_no_label(self):
        live = {"format": "herdr-live-v1", "snapshot": {
            "workspaces": [{"workspace_id": "w1", "label": "api", "active_tab_id": "t1"}],
            "tabs": [{"tab_id": "t1", "workspace_id": "w1", "label": "dev"}],
            "panes": [{"pane_id": "w1:p1"}]},
            "exports": {"t1": {"root": {"type": "pane", "pane_id": "w1:p1", "cwd": "/tmp"}}}}
        self.assertIsNone(normalize(live, "default")[0]["tabs"][0]["tree"]["label"])

    def test_resume_flag_is_gone(self):
        with self.assertRaises(SystemExit), patch("sys.stderr"):
            main(["--resume-agents", "--dry-run"])

    def test_portable_export_socket_envelope(self):
        export = {'result':{'layout':{'workspace_id':'w1','tab_id':'w1:t1',
                  'root':{'type':'pane','pane_id':'w1:p1','cwd':'/tmp'}}}}
        self.assertEqual(normalize(export,'offline')[0]['tabs'][0]['tree']['cwd'],'/tmp')


class FakeRex:
    server = None
    def __init__(self):
        self.sessions, self.created, self.fail_after_create = [], 0, True
    def call(self, name, args=None):
        args = args or {}
        if name == 'server.status':
            return {'instance_id':'instance-1'}
        if name == 'session.list':
            return {'sessions':self.sessions.copy()}
        if name == 'session.create':
            self.created += 1
            self.sessions.append({'session_id':'session:1', 'label':args['label']})
            if self.fail_after_create:
                self.fail_after_create = False
                raise Error('lost response')
        if name == 'session.set_label':
            self.sessions[0]['label'] = args['label']
        return {}
    def create_session(self, args):
        return self.call('session.create', args)


class RecoveryTests(unittest.TestCase):
    def test_lost_response_reconciles_and_repeat_does_not_duplicate(self):
        rex = FakeRex()
        w = normalize(fixture(), 'default')
        with tempfile.TemporaryDirectory() as tmp, patch('sources.herdr.bind_existing', return_value=[]):
            state = Path(tmp)
            with self.assertRaisesRegex(Error, 'lost response'):
                import_workspaces(rex, w, [], state, 'key')
            block = {'pane_id':'3', 'block_id':'b3', 'window_id':'win', 'label':'3', 'cwd':'/tmp'}
            with patch('sources.herdr.bind_existing', return_value=[block]):
                import_workspaces(rex, w, [], state, 'key')
                import_workspaces(rex, w, [], state, 'key')
            self.assertEqual(rex.created, 1)

    def test_missing_and_changed_server_do_not_resurrect(self):
        rex = FakeRex()
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp)
            receipt = {'state':'complete', 'instance_id':'old', 'resources':[]}
            atomic_json(state/'key.json', receipt)
            with self.assertRaisesRegex(Error, 'instance changed'):
                import_workspaces(rex, [], [], state, 'key')
            receipt.update(instance_id='instance-1', resources=[{'session_id':'missing'}])
            atomic_json(state/'key.json', receipt)
            with self.assertRaisesRegex(Error, 'were closed'):
                import_workspaces(rex, [], [], state, 'key')
            self.assertEqual(rex.created, 0)


if __name__ == '__main__':
    unittest.main()
