"""Exercise yt-dlp's real format selector without contacting a media host."""
import copy
import json
from pathlib import Path
from yt_dlp import YoutubeDL

# Read the selectors from the production source, rather than duplicating them.
import re
source = (Path(__file__).parents[1] / 'src' / 'yt-dlp.js').read_text(encoding='utf-8')
selectors = dict(re.findall(r"^  (automatic|dataSaver): '([^']+)'", source, re.M))
formats = [{
    'format_id': str(abr), 'ext': 'm4a', 'acodec': 'mp4a.40.2', 'vcodec': 'none',
    'abr': abr, 'asr': 44100, 'url': f'https://media.example/{abr}.m4a',
} for abr in [48, 128, 256]]

def resolve(mode, available):
    info = {'id': 'fixture0001', 'title': 'Quality test', 'formats': copy.deepcopy(available),
            'extractor': 'fixture', 'extractor_key': 'Fixture', 'webpage_url': 'https://example.com/fixture'}
    with YoutubeDL({'quiet': True, 'no_warnings': True, 'skip_download': True, 'format': selectors[mode]}) as ydl:
        return ydl.process_ie_result(info, download=False)

low = resolve('dataSaver', formats)
best = resolve('automatic', formats)
assert low['format_id'] == '48', low
assert best['format_id'] == '256', best
assert low['url'] != best['url']
assert low['acodec'] == best['acodec'] == 'mp4a.40.2'
single_low = resolve('dataSaver', [formats[1]])
single_best = resolve('automatic', [formats[1]])
assert single_low['format_id'] == single_best['format_id'] == '128'
print(json.dumps({'dataSaver': low['format_id'], 'bestAvailable': best['format_id'],
                  'singleAvailableFormat': single_best['format_id'], 'transcoding': False}))
