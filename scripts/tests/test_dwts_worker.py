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


    # Late-season weeks (fixtures/late-season-week.html follows the season 32–34 layouts).
    LATE = {
        'week_couples': [
            {'partnership_id': 'p-amber', 'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'},
            {'partnership_id': 'p-connor', 'star_name': 'Connor Wood', 'pro_name': 'Rylee Arnold'},
            {'partnership_id': 'p-ezra', 'star_name': 'Ezra Frech', 'pro_name': 'Daniella Karagach'}],
        'week_dances': [
            {'dance_id': f'{who}-{n}', 'star_name': star, 'pro_name': pro, 'round': n}
            for n in (1, 2) for who, star, pro in (('amber', 'Amber Glenn', 'Pasha Pashkov'),
                ('connor', 'Connor Wood', 'Rylee Arnold'), ('ezra', 'Ezra Frech', 'Daniella Karagach'))],
        'week_specials': [], 'formats': ['second_dance', 'team_dance', 'dance_off', 'marathon']}

    def late_result(self, mode, specials=None):
        html = (Path(__file__).parent / 'fixtures/late-season-week.html').read_text()
        task = {'mode': mode, 'week_tag': '#Week_7:_Test_Night', 'targets': [], **self.LATE}
        if specials is not None:
            task['week_specials'] = specials
        with patch.object(self.w.wiki, 'fetch_page', return_value=(html, 1)):
            return self.w.gather(task)

    def test_late_season_rounds_map_to_each_dance(self):
        result = self.late_result('live-show')
        by = {c['star_name']: c['by_dance'] for c in result['couples']}
        self.assertEqual(by['Amber Glenn']['amber-1']['total'], 32)
        self.assertEqual(by['Amber Glenn']['amber-2']['total'], 36)
        self.assertEqual(by['Connor Wood']['connor-2']['dance'], 'Salsa')
        # Ezra's second dance isn't on Wikipedia yet: his one row is dance 1, dance 2 stays empty.
        self.assertEqual(by['Ezra Frech']['ezra-1']['total'], 38)
        self.assertIsNone(by['Ezra Frech']['ezra-2'])
        self.assertEqual(result['errors'], [])
        # Team, marathon and dance-off rows are never a couple's performance.
        self.assertEqual([len(c['performances']) for c in result['couples']], [2, 2, 1])

    def test_late_season_post_show_uses_the_couples_result_for_every_round(self):
        result = self.late_result('post-show')
        by = {c['star_name']: c['by_dance'] for c in result['couples']}
        self.assertTrue(by['Connor Wood']['connor-1']['eliminated'])
        self.assertTrue(by['Connor Wood']['connor-2']['eliminated'])
        self.assertFalse(by['Amber Glenn']['amber-2']['eliminated'])

    def test_late_season_specials(self):
        result = self.late_result('live-show')
        team, match, marathon = result['specials']
        self.assertEqual((team['kind'], team['team_name'], team['dance'], team['total']), ('team', 'Team Roar', 'Freestyle', 37))
        # Julianne Hough (not a couple) is in the Couple cell and is ignored.
        self.assertEqual([c['partnership_id'] for c in team['couples']], ['p-amber', 'p-connor', 'p-ezra'])
        self.assertEqual((match['bonus_kind'], match['dance'], match['winner']), ('dance_off', 'Cha-cha-cha', 'p-amber'))
        self.assertEqual({c['partnership_id']: c['points'] for c in marathon['couples']},
                         {'p-amber': 3, 'p-connor': 1, 'p-ezra': 2})
        self.assertEqual(marathon['name'], 'Hustle & Lindy Hop Marathon')
        self.assertTrue(all(s['dance_id'] is None for s in result['specials']))
        # Existing dances are matched by team name, by the match's couples, and the week's one marathon.
        existing = [
            {'dance_id': 'team-1', 'kind': 'team', 'team_name': 'Roar', 'couples': []},
            {'dance_id': 'off-1', 'kind': 'bonus', 'bonus_kind': 'dance_off', 'couples': ['p-connor', 'p-amber']},
            {'dance_id': 'off-2', 'kind': 'bonus', 'bonus_kind': 'dance_off', 'couples': ['p-ezra', 'p-amber']},
            {'dance_id': 'mara-1', 'kind': 'bonus', 'bonus_kind': 'marathon', 'couples': []}]
        matched = self.late_result('live-show', existing)
        self.assertEqual([s['dance_id'] for s in matched['specials']], ['team-1', 'off-1', 'mara-1'])

    def test_team_rows_named_by_their_co_host(self):
        # Season 35's Disney Night: the co-host's name above the couples, a plain "Freestyle",
        # the film in the Music cell, and an extra theme column.
        html = (Path(__file__).parent / 'fixtures/co-host-teams-week.html').read_text()
        couples = self.LATE['week_couples'] + [
            {'partnership_id': 'p-harry', 'star_name': 'Harry Shum Jr.', 'pro_name': 'Jenna Johnson'}]
        task = {'mode': 'pre-show', 'week_tag': '#Week_8:_Disney_Night', 'targets': [], **self.LATE,
                'week_couples': couples, 'formats': ['team_dance'],
                'week_specials': [
                    {'dance_id': 'team-a', 'kind': 'team', 'team_name': 'Team Alfonso', 'couples': ['p-amber']},
                    {'dance_id': 'team-j', 'kind': 'team', 'team_name': 'Team Julianne', 'couples': ['p-connor', 'p-ezra']}]}
        with patch.object(self.w.wiki, 'fetch_page', return_value=(html, 1)):
            result = self.w.gather(task)
        alfonso, julianne = result['specials']
        self.assertEqual((alfonso['team_name'], alfonso['dance'], alfonso['song'], alfonso['dance_id']),
                         ('Team Alfonso', 'Freestyle', 'Zoo', 'team-a'))
        self.assertEqual(julianne['song'], "We're All in This Together")
        self.assertEqual([c['partnership_id'] for c in julianne['couples']], ['p-connor', 'p-ezra'])
        self.assertEqual((julianne['team_name'], julianne['dance_id']), ('Team Julianne', 'team-j'))
        # The team rows aren't anyone's own dance; each couple keeps its one performance.
        self.assertEqual([c['partnership_id'] for c in alfonso['couples']], ['p-amber', 'p-harry'])
        self.assertEqual([len(c['performances']) for c in result['couples']], [1, 1, 1, 1])
        self.assertEqual(result['couples'][0]['performances'][0]['dance'], 'Quickstep')
        # Live: the team's score row is read the same way, and the couples' own rows are untouched.
        scored = html.replace('<td>Freestyle</td><td colspan="2">"Zoo"', '<td>Freestyle</td><td colspan="2">"Zoo"', 1)
        scored = scored.replace('Harry &amp; Jenna</td><td></td><td>Freestyle', 'Harry &amp; Jenna</td><td>36 (9, 9, 9, 9)</td><td>Freestyle', 1)
        with patch.object(self.w.wiki, 'fetch_page', return_value=(scored, 1)):
            live = self.w.gather({**task, 'mode': 'live-show'})
        team = next(t for t in live['specials'] if t['team_name'] == 'Team Alfonso')
        self.assertEqual((team['total'], team['scores'], team['dance_id']), (36, [9, 9, 9, 9], 'team-a'))
        self.assertEqual(live['errors'], [])

    def test_late_season_rounds_with_instant_and_freestyle(self):
        wiki = self.w.wiki
        dances = [{'dance_id': 'r1', 'star_name': 'A B', 'pro_name': 'C D', 'round': 1, 'round_label': "Judges' Pick"},
                  {'dance_id': 'r2', 'star_name': 'A B', 'pro_name': 'C D', 'round': 2, 'round_label': 'Instant Dance'},
                  {'dance_id': 'r3', 'star_name': 'A B', 'pro_name': 'C D', 'round': 3, 'round_label': 'Freestyle'}]
        def mapped(perfs, mode='pre-show', known=None):
            rows = [dict(d, **(known or {}).get(d['dance_id'], {})) for d in dances]
            result = {'mode': mode, 'couples': [{'star_name': 'A B', 'pro_name': 'C D', 'found': True, 'performances': perfs}]}
            wiki.map_rounds(result, rows)
            return {k: v and v['dance'] for k, v in result['couples'][0]['by_dance'].items()}, result['errors']
        # Before the show: the announced dances only; the instant round waits for its row.
        self.assertEqual(mapped([{'dance': 'Jive'}, {'dance': 'Freestyle'}])[0], {'r1': 'Jive', 'r2': None, 'r3': 'Freestyle'})
        # On the night: three rows in order.
        self.assertEqual(mapped([{'dance': 'Jive'}, {'dance': 'Samba'}, {'dance': 'Freestyle'}])[0],
                         {'r1': 'Jive', 'r2': 'Samba', 'r3': 'Freestyle'})
        # A style already saved on a round wins over row order.
        self.assertEqual(mapped([{'dance': 'Samba'}, {'dance': 'Jive'}], known={'r1': {'dance_type': 'Jive'}})[0],
                         {'r1': 'Jive', 'r2': None, 'r3': 'Samba'})
        # More rows than dances: nothing is guessed.
        result, errors = mapped([{'dance': 'Jive'}] * 4)
        self.assertEqual(result, {'r1': None, 'r2': None, 'r3': None})
        self.assertEqual(len(errors), 3)

    def test_season_32_to_34_layouts(self):
        wiki = self.w.wiki
        html = '''<h2 id="Weekly_scores">Weekly scores</h2><h3 id="Week_9:_Test">Week 9: Test</h3>
            <table><tr><th>Couple</th><th>Scores</th><th>Dance</th><th>Music</th><th>Result</th></tr>
            <tr><td>Robert &amp; Witney</td><td>40 (10, 10, 10, 10)</td><td>Foxtrot</td><td>"Footprints" — Leona Lewis</td><td>Safe</td></tr>
            <tr><td>Alfonso Ribeiro Robert &amp; Witney Alix &amp; Val</td><td>38 (9, 10, 10, 9)</td><td>Freestyle (Team Kool)</td>
                <td colspan="2">"Celebration" — Kool &amp; the Gang</td></tr></table>
            <table><tr><th>Couple</th><th>Dance</th><th>Music</th><th>Result</th></tr>
            <tr><td>Robert &amp; Xochitl Gomez (Season 32 winner)</td><td rowspan="2">Jive Relay</td><td rowspan="2">"Dance with Me Tonight" — Olly Murs</td><td>Winners</td></tr>
            <tr><td>Alix &amp; Joey Graziadei (Season 33 winner)</td><td>Losers</td></tr></table>'''
        couples = {'Robert Irwin': 'Witney Carson', 'Alix Earle': 'Val Chmerkovskiy'}
        result = wiki.parse_information(html, 'pre-show', couples, '#Week_9:_Test')
        self.assertEqual([len(c['performances']) for c in result['couples']], [1, 0])
        self.assertEqual(result['teams'][0]['team_name'], 'Team Kool')
        self.assertEqual(len(result['teams'][0]['couples']), 2)
        # Relay partners are past winners, so the star's first name finds the couple.
        match = result['matches'][0]
        self.assertEqual((match['kind'], match['dance']), ('relay', 'Jive'))
        self.assertEqual([(c['star_name'], c['result']) for c in match['couples']],
                         [('Robert Irwin', 'winner'), ('Alix Earle', 'loser')])

    def test_ordinary_weeks_send_no_round_mapping(self):
        task = {'mode': 'live-show', 'week_tag': '#Week_4:_Test',
                'targets': [{'dance_id': 'd', 'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}]}
        html = '''<h2 id="Weekly_scores">Weekly scores</h2><h3 id="Week_4:_Test">Week 4: Test</h3>
            <table><tr><th>Couple</th><th>Scores</th></tr><tr><td>Amber &amp; Pasha</td><td>24 (8, 8, 8)</td></tr></table>'''
        with patch.object(self.w.wiki, 'fetch_page', return_value=(html, 1)):
            result = self.w.gather(task)
        self.assertNotIn('by_dance', result['couples'][0])
        self.assertNotIn('specials', result)


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
