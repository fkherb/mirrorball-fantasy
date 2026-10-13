import importlib.util
import io
import json
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('official_photos', Path(__file__).parents[1] / 'Automations/dwts-photos.py')
photos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(photos)


class OfficialXTests(unittest.TestCase):
    def test_media_keys_not_array_order_and_skip_video(self):
        data = {'data': [{'id': '123', 'author_id': photos.X_USER_ID, 'text': 'A couple',
            'created_at': '2026-10-13T20:00:00Z', 'attachments': {'media_keys': ['second', 'video', 'first']}}],
            'includes': {'media': [{'media_key': 'first', 'type': 'photo', 'url': 'one'},
                {'media_key': 'second', 'type': 'photo', 'url': 'two'}, {'media_key': 'video', 'type': 'video'}]}}
        with patch.object(photos, 'x_request', return_value=data) as request:
            posts = photos.fetch_posts(photos.HANDLE, 'secret', datetime(2026, 10, 13, tzinfo=timezone.utc))
        self.assertEqual([m['url'] for m in posts[0]['media']], ['two', 'one'])
        self.assertEqual(request.call_args.args[2]['start_time'], '2026-10-13T00:00:00Z')
        self.assertEqual(request.call_args.args[0], 'users/16222584/tweets')

    def test_pagination_is_bounded_and_visible(self):
        diagnostics = photos.new_result(5, [], True)['diagnostics']
        with patch.object(photos, 'x_request', return_value={'meta': {'next_token': 'next'}}) as request:
            self.assertEqual(photos.fetch_posts(photos.HANDLE, 'token', diagnostics=diagnostics), [])
        self.assertEqual(request.call_count, 3)
        self.assertIn('timeline_page_limit_reached', diagnostics['warnings'])

    def test_missing_token_never_calls_network(self):
        with patch.object(photos.urllib.request, 'build_opener') as network:
            with self.assertRaisesRegex(photos.PhotoError, 'DWTS_X_BEARER_TOKEN'):
                photos.x_request('users/16222584/tweets', '', {})
            network.assert_not_called()

    def test_incomplete_media_fails_closed(self):
        for data in [{'errors': [{'detail': 'private-token'}]}, {'data': [{'id': '123',
            'author_id': photos.X_USER_ID, 'created_at': '2026-10-13T20:00:00Z',
            'text': 'test', 'attachments': {'media_keys': ['missing']}}]}]:
            with patch.object(photos, 'x_request', return_value=data):
                with self.assertRaises(photos.PhotoError) as error:
                    photos.fetch_posts(photos.HANDLE, 'token')
                self.assertNotIn('private-token', str(error.exception))

    def test_safe_http_errors_and_cooldown(self):
        for status, message in [(401, 'DWTS_X_BEARER_TOKEN'), (402, 'credits'), (403, 'permissions'), (429, 'rate limit')]:
            error = urllib.error.HTTPError('https://api.x.com', status, 'error',
                {'Retry-After': '650'} if status == 429 else {}, io.BytesIO(b'private-token'))
            opener = Mock()
            opener.open.side_effect = error
            with patch.object(photos.urllib.request, 'build_opener', return_value=opener):
                with self.assertRaisesRegex(photos.PhotoError, message) as caught:
                    photos.x_request('users/16222584/tweets', 'private-token', {})
                self.assertNotIn('private-token', str(caught.exception))
                if status == 429:
                    self.assertEqual(caught.exception.seconds, 650)

    def test_download_uses_original_image_without_any_bearer(self):
        response = io.BytesIO(b'\xff\xd8\xff' + b'image fixture')
        response.headers = {'Content-Type': 'image/jpeg'}
        opener = Mock()
        opener.open.return_value = response
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(photos.urllib.request, 'build_opener', return_value=opener):
            files = photos.download_api_photos({'media': [{'url': 'https://pbs.twimg.com/media/example.jpg'}]}, directory)
            self.assertEqual(len(files), 1)
            self.assertEqual(files[0].suffix, '.jpeg')
            request = opener.open.call_args.args[0]
            self.assertTrue(request.full_url.endswith('?name=orig'))
            self.assertIsNone(request.get_header('Authorization'))

    def test_rejects_untrusted_host_and_non_images(self):
        with tempfile.TemporaryDirectory() as directory:
            for url in ['http://pbs.twimg.com/media/a.jpg', 'https://evil.example/a.jpg',
                        'https://pbs.twimg.com@evil.example/media/a.jpg', 'https://pbs.twimg.com/other/a.jpg']:
                with self.assertRaises(photos.PhotoError):
                    photos.download_api_photos({'media': [{'url': url}]}, directory)
            response = io.BytesIO(b'<html>not an image</html>')
            response.headers = {'Content-Type': 'image/jpeg'}
            opener = Mock()
            opener.open.return_value = response
            with patch.object(photos.urllib.request, 'build_opener', return_value=opener):
                with self.assertRaisesRegex(photos.PhotoError, 'image type'):
                    photos.download_api_photos({'media': [{'url': 'https://pbs.twimg.com/media/a.jpg'}]}, directory)

    def test_upload_includes_source_in_same_commit(self):
        couple = {'star_name': 'Amber Glenn', 'pro_name': 'Pasha Pashkov'}
        post = {'id_str': '123', 'created_at': 'Tue Oct 13 20:30:00 +0000 2026',
            'source_created_at': '2026-10-13T20:30:00Z', 'full_text': 'Amber Glenn and Pasha Pashkov',
            'media': [{'type': 'photo', 'url': 'https://pbs.twimg.com/media/example.jpg'}]}
        def commit(files, message, token):
            self.assertEqual(len(files), 2)
            source = json.loads(files[1][1].read_text())
            self.assertEqual(source['image_path'], files[0][0])
            self.assertEqual(source['post_url'], 'https://x.com/officialdwts/status/123')
            self.assertNotIn('secret', json.dumps(source))
            return 'a' * 40
        with tempfile.TemporaryDirectory() as directory:
            image = Path(directory) / 'photo.jpeg'
            image.write_bytes(b'image')
            with patch.object(photos, 'fetch_posts', return_value=[post]), \
                 patch.object(photos, 'remote_files', return_value=[]), \
                 patch.object(photos, 'download_api_photos', return_value=[image]), \
                 patch.object(photos, 'commit_files', side_effect=commit):
                result = photos.run(5, [couple], 'git-secret', '2026-10-13',
                    external_state={'downloaded': {}}, x_token='x-secret')
        self.assertFalse(result['failed_run'], result)
        self.assertEqual(result['diagnostics']['uploaded_files'], 1)


if __name__ == '__main__':
    unittest.main()
