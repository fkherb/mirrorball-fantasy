from datetime import timedelta
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('worker', Path(__file__).parents[1] / 'Automations/dwts-worker.py')
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.w = worker.Worker({'SUPABASE_URL': 'https://example.supabase.co',
            'DWTS_AUTOMATION_WORKER_SECRET': 's' * 48, 'DWTS_PHOTOS_GITHUB_TOKEN': 'private-token',
            'DWTS_X_BEARER_TOKEN': 'private-x-token'},
            Path(self.tmp.name))

    def test_durable_redacted_outbox_and_retry(self):
        path = self.w.persist('run', {'error': 'private-token private-x-token ' + 's' * 48})
        self.assertNotIn('private-token', path.read_text())
        self.assertNotIn('private-x-token', path.read_text())
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        with patch.object(self.w, 'api', side_effect=worker.ApiError(503, 'offline')):
            with self.assertRaises(worker.ApiError):
                self.w.flush(path)
        self.assertTrue(path.exists())
        with patch.object(self.w, 'api', return_value={}):
            self.w.flush(path)
        self.assertFalse(path.exists())

    def test_manual_github_photos_skip_x(self):
        target = {'dance_id': 'dance', 'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}
        task = {'run_id': 'run', 'mode': 'photos', 'week': 4, 'targets': [target], 'folder': 'Images/Dances/Week 4'}
        with patch.object(self.w.photos, 'remote_files', return_value=['Amber Glenn and Pasha Pashkov-1.avif']), \
             patch.object(self.w.photos, 'gh', return_value={'object': {'sha': 'a' * 40}}), \
             patch.object(self.w, 'api', return_value={'verified_dance_ids': ['dance']}), \
             patch.object(self.w.photos, 'fetch_posts') as fetch:
            result = self.w.photo_result(task)
        self.assertFalse(result['failed_run'])
        self.assertEqual(result['remaining_couples'], [])
        self.assertEqual(result['diagnostics']['reconciled_couples'], 1)
        self.assertEqual(result['diagnostics']['outcome'], 'already_satisfied')
        fetch.assert_not_called()

    def test_photo_receipts_and_external_state(self):
        photos = self.w.photos
        couple = {'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}
        post = {'id_str': '123', 'created_at': 'Tue Oct 06 20:30:00 +0000 2026',
            'full_text': 'Amber Glenn Pasha Pashkov', 'source_created_at': '2026-10-06T20:30:00Z',
            'media': [{'type': 'photo', 'url': 'https://pbs.twimg.com/media/example.jpg'}]}
        local = Path(self.tmp.name) / 'photo.jpg'
        local.write_bytes(b'image fixture')
        with patch.object(photos, 'fetch_posts', return_value=[post, {**post, 'id_str': '124'}]), \
             patch.object(photos, 'remote_files', return_value=[]), \
             patch.object(photos, 'download_api_photos', return_value=[local]) as download, \
             patch.object(photos, 'commit_files', return_value='a' * 40), \
             patch.object(photos, 'load_state') as load, patch.object(photos, 'save_state') as save:
            result = photos.run(4, [couple], 'token', since='2026-10-06', external_state={'downloaded': {}})
        self.assertFalse(result['failed_run'], result)
        receipt = result['uploaded_couples'][0]
        self.assertEqual(receipt['post_ids'], ['123'])
        self.assertEqual(receipt['commit_sha'], 'a' * 40)
        self.assertEqual(download.call_count, 1)
        load.assert_not_called()
        save.assert_not_called()

    def test_preview_never_reconciles_or_uploads(self):
        task = {'mode': 'photos', 'week': 3, 'targets': [{'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}]}
        with patch.object(self.w.photos, 'run', return_value=self.w.photos.new_result(3, task['targets'], True)) as run, patch.object(self.w, 'api') as api:
            self.w.gather(task, preview=True)
        self.assertTrue(run.call_args.kwargs['dry_run'])
        api.assert_not_called()

    def test_get_weeks_omits_couples(self):
        with patch.object(self.w.wiki, 'fetch_information', return_value={'weeks': []}) as fetch:
            self.w.gather({'mode': 'get-weeks', 'targets': []})
        fetch.assert_called_once_with('get-weeks')

    def test_repository_setting_routes_reads_writes_and_receipts(self):
        self.assertEqual(self.w.photos.GITHUB_REPO, 'fkherb/mirrorball-fantasy-league')
        config = {'SUPABASE_URL': 'https://example.supabase.co',
            'DWTS_AUTOMATION_WORKER_SECRET': 's' * 48,
            'DWTS_GITHUB_REPOSITORY': 'fkherb/mirrorball-fantasy'}
        renamed = worker.Worker(config, Path(self.tmp.name))
        photos = renamed.photos
        with patch.object(photos, 'http_json_or_text', return_value={}) as request:
            photos.gh('GET', '/git/ref/heads/main', 'token')
            self.assertEqual(request.call_args.args[0],
                'https://api.github.com/repos/fkherb/mirrorball-fantasy/git/ref/heads/main')
            photos.gh('PATCH', '/git/refs/heads/main', 'token', {'sha': 'a' * 40})
            self.assertIn('/repos/fkherb/mirrorball-fantasy/', request.call_args.args[0])
        self.assertEqual(photos.new_result(5, [], True)['repository'], 'fkherb/mirrorball-fantasy')
        for invalid in ['', 'https://github.com/fkherb/mirrorball-fantasy', '../other',
                        'fkherb/../other', 'fkherb/repo?token=secret']:
            with self.assertRaises(photos.PhotoError):
                photos.configure_github_repository(invalid)
        self.assertEqual(photos.GITHUB_REPO, 'fkherb/mirrorball-fantasy')

    def test_live_wiki_scores_include_table_row_position(self):
        html = '''<h2 id="Weekly_scores">Weekly scores</h2>
            <h3 id="Week_4:_Test">Week 4: Test</h3>
            <table><tr><th>Couple</th><th>Scores</th></tr>
            <tr><td>Amber &amp; Pasha</td><td>8, 8, 8 = 24</td></tr>
            <tr><td>Connor &amp; Rylee</td><td>7, 7, 7 = 21</td></tr></table>'''
        result = self.w.wiki.parse_information(html, 'live-show',
            {'Amber Glenn': 'Pasha Pashkov', 'Connor Wood': 'Rylee Arnold'},
            '#Week_4:_Test')
        positions = [item['performances'][0]['row_index'] for item in result['couples']]
        self.assertEqual(positions, [1, 2])
        self.assertEqual([item['performances'][0]['table_index'] for item in result['couples']], [0, 0])


    def test_post_show_no_elimination_text_marks_every_couple_safe(self):
        html = '''<h2 id="Weekly_scores">Weekly scores</h2>
            <h3 id="Week_6:_Test">Week 6: Test</h3>
            <p>Each couple performed one unlearned dance. No elimination took place this week;
            all scores were carried over to the following week.</p>
            <table><tr><th>Couple</th><th>Scores</th><th>Dance</th></tr>
            <tr><td>Amber &amp; Pasha</td><td>38 (10, 9, 10, 9)</td><td>Contemporary</td></tr></table>'''
        couples = {'Amber Glenn': 'Pasha Pashkov', 'Connor Wood': 'Rylee Arnold'}
        result = self.w.wiki.parse_information(html, 'post-show', couples, '#Week_6:_Test')
        self.assertTrue(result.get('no_elimination'))
        self.assertEqual([c['performances'] for c in result['couples']], [[{'eliminated': False}]] * 2)
        # Without that sentence (results not posted yet), nothing is guessed.
        pending = self.w.wiki.parse_information(html.replace('No elimination took place this week;', ''),
                                                'post-show', couples, '#Week_6:_Test')
        self.assertFalse(pending.get('no_elimination'))
        self.assertFalse(any(c['found'] for c in pending['couples']))


    def test_until_idle_exits_when_nothing_is_due_soon(self):
        far = '2099-01-01T00:00:00+00:00'
        with patch.object(self.w, 'api', return_value={'run_id': None, 'next_run_at': far}) as api, \
             patch.object(worker.time, 'sleep') as sleep:
            self.w.run(until_idle=10)
        api.assert_called_once_with('claim')
        sleep.assert_not_called()

    def test_until_idle_waits_for_a_job_due_soon(self):
        soon = (worker.datetime.now(worker.timezone.utc) + timedelta(minutes=4)).isoformat()
        responses = [{'run_id': None, 'next_run_at': soon}, {'run_id': None, 'next_run_at': None}]
        with patch.object(self.w, 'api', side_effect=responses) as api, \
             patch.object(worker.time, 'sleep') as sleep:
            self.w.run(until_idle=10)
        self.assertEqual(api.call_count, 2)
        sleep.assert_called_once_with(60)

    def test_due_within(self):
        self.assertFalse(self.w.due_within(None, 10))
        self.assertFalse(self.w.due_within('not a date', 10))
        self.assertTrue(self.w.due_within('2000-01-01T00:00:00Z', 10))
        self.assertFalse(self.w.due_within('2099-01-01T00:00:00Z', 10))

if __name__ == '__main__':
    unittest.main()
