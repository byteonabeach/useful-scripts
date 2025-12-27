import os
import re
import shutil
import argparse
import threading
from collections import defaultdict, Counter
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, as_completed
from mutagen import File
from mutagen.id3 import ID3, TPE1, TPE2, TALB, TIT2, ID3NoHeaderError
from mutagen.flac import FLAC
from mutagen.mp4 import MP4
from unidecode import unidecode
from tqdm import tqdm

class TagFixer:
    MOJIBAKE_CHARS = set('ÂÃâãÐÑÒÓÔÕÖ×ØÙÚÛÜÝÞßàáâãäåæçèéêëìíîïðñòóôõö÷øùúûüýþÿĀāĂăĄą')
    
    def __init__(self, music_dir, dry_run=False, backup=True, max_workers=None):
        self.music_dir = Path(music_dir)
        self.dry_run = dry_run
        self.backup = backup
        self.max_workers = max_workers
        
        self.artist_variants = defaultdict(Counter)
        self.album_variants = defaultdict(Counter)
        self.canonical_artists = {}
        self.canonical_albums = {}
        self.file_data = []
        
        self.stats = {
            'scanned': 0,
            'modified': 0,
            'encoding_fixed': 0,
            'errors': 0
        }
        self.stats_lock = threading.Lock()
        self.print_lock = threading.Lock()

    def has_mojibake(self, text):
        if not text:
            return False
        return any(char in self.MOJIBAKE_CHARS for char in text)

    def has_cyrillic(self, text):
        if not text:
            return False
        return any('\u0400' <= char <= '\u04FF' for char in text)

    def fix_encoding(self, text):
        if not text:
            return ""
        if self.has_cyrillic(text) and not self.has_mojibake(text):
            return text
        if self.has_mojibake(text):
            for source_enc, target_enc in [
                ('latin-1', 'cp1251'),
                ('latin-1', 'cp866'),
                ('latin-1', 'koi8-r'),
                ('cp1252', 'cp1251')
            ]:
                try:
                    fixed = text.encode(source_enc).decode(target_enc)
                    if self.has_cyrillic(fixed) and not self.has_mojibake(fixed):
                        return fixed
                except (UnicodeDecodeError, UnicodeEncodeError):
                    continue
        return text

    def normalize_key(self, text):
        if not text:
            return ""
        normalized = unidecode(str(text)).lower()
        normalized = re.sub(r'[^\w\s]', '', normalized)
        return ' '.join(normalized.split())

    def heuristic_split_artists(self, artist_list):
        if not artist_list:
            return []
        delimiters = [
            r'\s+feat\.?\s+', r'\s+ft\.?\s+', r'\s+featuring\s+',
            r'\s+&\s+', r'\s+and\s+', r'\s+и\s+',
            r'\s+with\s+', r'\s+при\s+уч\.?\s+',
            r'\s+vs\.?\s+', r'\s+v\.s\.?\s+',
            r'\s*[/;|]\s*',
            r'\s+\.\s+'
        ]
        pattern = '|'.join(delimiters)
        result = []
        for artist in artist_list:
            artist = re.sub(r'^\((.*)\)$', r'\1', artist.strip())
            parts = re.split(pattern, artist, flags=re.IGNORECASE)
            for p in parts:
                p = p.strip()
                p = p.rstrip(')').lstrip('(')
                if p:
                    result.append(p)
        seen = set()
        return [x for x in result if not (x.lower() in seen or seen.add(x.lower()))]

    def read_tags(self, filepath):
        try:
            audio = File(filepath)
            if audio is None:
                if filepath.suffix.lower() == '.mp3':
                    try:
                        audio = ID3(filepath)
                    except:
                        return None
                else:
                    return None
            tags = {'artists': [], 'album': '', 'title': ''}
            if isinstance(audio, MP4):
                artist_keys = ['\xa9ART', 'aART']
            elif isinstance(audio, (FLAC, dict)):
                artist_keys = ['artist', 'albumartist']
            else:
                artist_keys = ['TPE1', 'TPE2']
            for key in artist_keys:
                val = audio.get(key)
                if val:
                    if hasattr(val, 'text'): val = val.text
                    if isinstance(val, str): val = [val]
                    tags['artists'].extend([str(v) for v in val if v])
            seen = set()
            unique_artists = []
            for artist in tags['artists']:
                if artist not in seen:
                    seen.add(artist)
                    unique_artists.append(artist)
            tags['artists'] = unique_artists
            album_key = '\xa9alb' if isinstance(audio, MP4) else ('album' if isinstance(audio, (FLAC, dict)) else 'TALB')
            val = audio.get(album_key)
            if val:
                if hasattr(val, 'text'): val = val.text[0]
                elif isinstance(val, list): val = val[0]
                tags['album'] = str(val)
            title_key = '\xa9nam' if isinstance(audio, MP4) else ('title' if isinstance(audio, (FLAC, dict)) else 'TIT2')
            val = audio.get(title_key)
            if val:
                if hasattr(val, 'text'): val = val.text[0]
                elif isinstance(val, list): val = val[0]
                tags['title'] = str(val)
            return tags
        except Exception:
            return None

    def _scan_file_task(self, filepath):
        tags = self.read_tags(filepath)
        if tags is None:
            return None
        fixed_artists_raw = [self.fix_encoding(a) for a in tags['artists']]
        split_artists = self.heuristic_split_artists(fixed_artists_raw)
        fixed_album = self.fix_encoding(tags['album'])
        fixed_title = self.fix_encoding(tags['title'])
        return {
            'path': filepath,
            'original': tags,
            'fixed_artists': split_artists,
            'fixed_album': fixed_album,
            'fixed_title': fixed_title
        }

    def scan_library(self):
        supported = {'.mp3', '.flac', '.m4a', '.mp4', '.ogg', '.opus'}
        files = [f for f in self.music_dir.rglob('*') if f.suffix.lower() in supported]
        print(f"\nSTEP 1: Library Analysis")
        print(f"Files found: {len(files)}\n")
        
        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = {executor.submit(self._scan_file_task, f): f for f in files}
            for future in tqdm(as_completed(futures), total=len(files), desc="Scanning"):
                result = future.result()
                if result:
                    with self.stats_lock:
                        self.stats['scanned'] += 1
                    for artist in result['fixed_artists']:
                        if artist:
                            key = self.normalize_key(artist)
                            if key: self.artist_variants[key][artist] += 1
                    if result['fixed_album']:
                        key = self.normalize_key(result['fixed_album'])
                        if key: self.album_variants[key][result['fixed_album']] += 1
                    self.file_data.append(result)
                else:
                    with self.stats_lock:
                        self.stats['errors'] += 1

        for key, variants in self.artist_variants.items():
            self.canonical_artists[key] = variants.most_common(1)[0][0]
        for key, variants in self.album_variants.items():
            self.canonical_albums[key] = variants.most_common(1)[0][0]
        print(f"\nStatistics:")
        print(f"   Unique artists: {len(self.canonical_artists)}")
        print(f"   Unique albums: {len(self.album_variants)}")

    def _apply_fix_task(self, data):
        filepath = data['path']
        original = data['original']
        target_artists = []
        for artist in data['fixed_artists']:
            if artist:
                key = self.normalize_key(artist)
                canonical = self.canonical_artists.get(key, artist)
                target_artists.append(canonical)
        if not target_artists: target_artists = ["Unknown Artist"]
        target_album = data['fixed_album']
        if target_album:
            key = self.normalize_key(target_album)
            target_album = self.canonical_albums.get(key, target_album)
        target_title = data['fixed_title']
        artists_changed = (target_artists != original['artists'])
        album_changed = (target_album != original['album'])
        title_changed = (target_title != original['title'])
        
        if artists_changed or album_changed or title_changed:
            with self.print_lock:
                tqdm.write(f"\nFile: {filepath.name}")
                if artists_changed: tqdm.write(f"   Artist:  {original['artists']} -> {target_artists}")
                if album_changed: tqdm.write(f"   Album:   '{original['album']}' -> '{target_album}'")
                if title_changed: tqdm.write(f"   Title:   '{original['title']}' -> '{target_title}'")
            
            if not self.dry_run:
                if self.write_tags(filepath, target_artists, target_album, target_title):
                    with self.stats_lock:
                        self.stats['modified'] += 1
                        self.stats['encoding_fixed'] += 1

    def apply_fixes(self):
        mode = "DRY RUN" if self.dry_run else "WRITING TO FILES"
        print(f"\nSTEP 2: Applying Changes ({mode})\n")
        with ThreadPoolExecutor(max_workers=self.max_workers) as executor:
            futures = [executor.submit(self._apply_fix_task, d) for d in self.file_data]
            for _ in tqdm(as_completed(futures), total=len(futures), desc="Processing"):
                pass

    def write_tags(self, filepath, artists, album, title):
        try:
            if self.backup:
                backup_path = str(filepath) + ".bak"
                if not os.path.exists(backup_path): shutil.copy2(filepath, backup_path)
            ext = filepath.suffix.lower()
            if ext == '.mp3':
                try: tags = ID3(filepath)
                except ID3NoHeaderError: tags = ID3()
                tags.delall('TPE1'); tags.delall('TPE2'); tags.delall('TALB'); tags.delall('TIT2')
                for artist in artists: tags.add(TPE1(encoding=3, text=artist))
                if artists: tags.add(TPE2(encoding=3, text=artists[0]))
                if album: tags.add(TALB(encoding=3, text=album))
                if title: tags.add(TIT2(encoding=3, text=title))
                tags.save(filepath, v2_version=4)
            elif ext in {'.flac', '.ogg', '.opus'}:
                audio = File(filepath)
                if audio:
                    audio['artist'] = artists
                    audio['albumartist'] = [artists[0]] if artists else []
                    if album: audio['album'] = [album]
                    if title: audio['title'] = [title]
                    audio.save()
            elif ext in {'.m4a', '.mp4'}:
                audio = File(filepath)
                if audio:
                    audio['\xa9ART'] = artists
                    audio['aART'] = [artists[0]] if artists else []
                    if album: audio['\xa9alb'] = [album]
                    if title: audio['\xa9nam'] = [title]
                    audio.save()
            return True
        except Exception as e:
            with self.print_lock: tqdm.write(f"   Error writing: {e}")
            with self.stats_lock: self.stats['errors'] += 1
            return False

    def print_summary(self):
        print("\n" + "="*50 + "\nFINAL STATISTICS\n" + "="*50)
        print(f"Files scanned:           {self.stats['scanned']}")
        print(f"Files modified:          {self.stats['modified']}")
        print(f"Encodings fixed:         {self.stats['encoding_fixed']}")
        print(f"Errors:                  {self.stats['errors']}\n" + "="*50)
        if self.dry_run: print("\nNotice: This was a dry run. Run without --dry to apply changes.\n")

    def run(self):
        self.scan_library()
        self.apply_fixes()
        self.print_summary()

def main():
    parser = argparse.ArgumentParser(description='Navidrome Tag Fixer - Thread-safe Parallel Version')
    parser.add_argument('directory', help='Path to music directory')
    parser.add_argument('--dry', action='store_true', help='Dry run mode')
    parser.add_argument('--no-backup', action='store_true', help='Disable .bak creation')
    parser.add_argument('--threads', type=int, default=None, help='Number of threads (default: CPU count)')
    args = parser.parse_args()
    if not os.path.isdir(args.directory):
        print(f"Error: Directory '{args.directory}' not found"); return 1
    fixer = TagFixer(music_dir=args.directory, dry_run=args.dry, backup=not args.no_backup, max_workers=args.threads)
    try:
        fixer.run(); return 0
    except KeyboardInterrupt:
        print("\n\nAborted by user"); return 130
    except Exception as e:
        print(f"\nCritical error: {e}"); return 1

if __name__ == "__main__":
    exit(main())
