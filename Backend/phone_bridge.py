"""Load Telos's reviewed phone plugin into isolated Hermes tasks.

The upstream plugin owns its tool, approval hook and phone implementation. This
host adapter supplies Telos's native approval surface and serializes different
task processes before entering the unchanged Hermes execution pipeline.
"""
import contextlib
import contextvars
import copy
import fcntl
import functools
import hashlib
import io
import json
import os
import shutil
import stat
import sys
import tempfile
import threading
import time
import uuid
from pathlib import Path

PLUGIN = 'phone-harness'
TOOL = 'phone_exec'
_BUNDLED_FILES = {
    'plugin.yaml': 'eeb996a944b6adea018a92de6739748247c536de2cbc064ebd9a6419d855a323',
    '__init__.py': '6dd4616ad458953accf2c01eeace08f944d56cfe14203e4f299ca771136e037b',
    'README.md': '2ed6620c4d55c982a6242534fc9dff5610ccc10b7636a04632b405d212113b2c',
}
_MIRROR_CHROME_SUBROLES = frozenset({'AXCloseButton', 'AXMinimizeButton', 'AXZoomButton'})
_MIRROR_TOOLBAR_IDS = frozenset({'app.grid.3x3', 'iphone.app.switcher'})
# Vision reports valid English app labels at 0.5 in the bilingual request.
# Exact query + section + unique label are the selection guards.
_SPOTLIGHT_MIN_CONFIDENCE = .45


def filter_mirror_chrome_nodes(nodes, attribute):
    """Exclude only verified Mac window chrome, retaining every unknown node.

    phone-harness 0.3.2 counts toolbar Home/App Switcher buttons as a blocking
    interstitial on current macOS. Labels are deliberately not used: a Connect
    button, a renamed/unknown control or any body text must still block input.
    """
    content = []
    for role, text, element in nodes:
        chrome = False
        if role == 'AXButton':
            try:
                chrome = (attribute(element, 'AXSubrole') in _MIRROR_CHROME_SUBROLES
                          or attribute(element, 'AXIdentifier') in _MIRROR_TOOLBAR_IDS)
            except Exception:
                # Missing/failed identity is never evidence that input is safe.
                chrome = False
        if not chrome:
            content.append((role, text, element))
    return content


def install_mirror_chrome_compat(mirror, package_version):
    """Process-local compatibility for the exact pinned package; no file edits."""
    if package_version != '0.3.2':
        return False
    original = mirror._window_ax_nodes
    if getattr(original, '_telos_chrome_compat', False):
        return True

    def attribute(element, name):
        error, value = mirror._AS.AXUIElementCopyAttributeValue(element, name, None)
        return None if error or value is None else str(value)

    @functools.wraps(original)
    def content(*args, **kwargs):
        return filter_mirror_chrome_nodes(original(*args, **kwargs), attribute)

    content._telos_chrome_compat = True
    mirror._window_ax_nodes = content
    return True


def install_phone_ocr_compat(ocr, package_version):
    """Configure this pinned OCR module's requests without changing its maths.

    Vision defaults to English, dropping Chinese labels from screen()/find_text.
    A module-local factory proxy preserves the upstream recognize() function and
    does not mutate the shared Objective-C class or other Vision clients.
    """
    if package_version != '0.3.2':
        return False
    vision = ocr.Vision
    if getattr(vision, '_telos_bilingual_ocr', False):
        return True

    class AllocatedRequest:
        def init(self):
            request = vision.VNRecognizeTextRequest.alloc().init()
            request.setRecognitionLanguages_(['zh-Hans', 'en-US'])
            return request

    class RequestFactory:
        @staticmethod
        def alloc():
            return AllocatedRequest()

    class VisionRequests:
        _telos_bilingual_ocr = True
        VNRecognizeTextRequest = RequestFactory

        def __getattr__(self, name):
            return getattr(vision, name)

    ocr.Vision = VisionRequests()
    return True


def _spotlight_text(text):
    return ''.join(str(text).split()).casefold()


def _spotlight_confirmed(rows, window):
    labels = {_spotlight_text(row.get('text', '')) for row in rows}
    strong = {'tophit', '最佳结果', '最佳匹配', 'sirisuggestions', 'siri建议', '搜索iphone', 'searchiphone'}
    if labels & strong:
        return True
    apps = labels & {'apps', '应用', '应用程序', 'app'}
    return bool(apps and any(_spotlight_text(row.get('text', '')) in {'search', '搜索'}
                            and row.get('y', 0) >= window['y'] + .85 * window['h'] for row in rows))


def _spotlight_app_result(rows, window, query, aliases, *, allow_wechat_top_hit=False):
    """Prefer an exact Apps label; only WeChat may use an exact Top Hit label."""
    bottom = window['y'] + .85 * window['h']
    query_visible = any(_spotlight_text(row.get('text', '')) == _spotlight_text(query)
                        and row.get('confidence', 0) >= _SPOTLIGHT_MIN_CONFIDENCE
                        and bottom <= row.get('y', 0) <= window['y'] + window['h'] for row in rows)
    if not query_visible:
        return None
    app_headers = {'apps', '应用', '应用程序', 'app'}
    top_headers = {'tophit', '最佳结果', '最佳匹配'}
    sections = app_headers | top_headers | {
        'searchinapps', '在app中搜索', '在应用中搜索', 'searchtheweb', '搜索网页',
        'websites', '网站', 'contacts', '联系人', 'sirisuggestions', 'siri建议',
        'suggestions', '建议', '搜索建议', 'files', '文件'}
    regions = [app_headers] + ([top_headers] if allow_wechat_top_hit else [])
    for region in regions:
        headers = [row for row in rows if _spotlight_text(row.get('text', '')) in region
                   and window['y'] <= row.get('y', 0) < bottom]
        if len(headers) != 1:
            continue
        start = headers[0]['y'] + headers[0].get('h', 0) / 2
        end = min([bottom] + [row['y'] - row.get('h', 0) / 2 for row in rows
                             if row.get('y', 0) > start and
                             _spotlight_text(row.get('text', '')) in sections])
        hits = [row for row in rows if _spotlight_text(row.get('text', '')) in aliases
                and row.get('confidence', 0) >= _SPOTLIGHT_MIN_CONFIDENCE and start < row.get('y', 0) < end
                and window['x'] <= row.get('x', 0) <= window['x'] + window['w']]
        if len(hits) > 1:
            raise ValueError('Spotlight has multiple exact app matches. No app was opened.')
        if len(hits) == 1:
            return hits[0]
    return None


def _launch_verified_spotlight(device, name, ios):
    """Wait for the query and an exact verified app label, then tap it."""
    wechat = _spotlight_text(name) in {'微信', 'wechat'}
    query = 'WeChat' if wechat else name
    aliases = {'微信', 'wechat'} if wechat else {_spotlight_text(name)}
    device.mirror.press('cmd+3')
    window = device.mirror.find_window()
    if not window:
        raise ValueError('Spotlight has no phone window. No query was typed.')
    for _ in range(16):
        rows = device._screen_text()
        if _spotlight_confirmed(rows, window):
            break
        ios._sleep(.25)
    else:
        raise ValueError('Spotlight was not confirmed. No query was typed or app opened.')
    device._raise_if_not_live()
    device.mirror.press('cmd+a')
    device.mirror.press('backspace')
    device.mirror.type_text(query, keystrokes=query.isascii())
    for _ in range(16):
        window = device.mirror.find_window()
        if not window:
            break
        hit = _spotlight_app_result(device._screen_text(), window, query, aliases,
                                    allow_wechat_top_hit=wechat)
        if hit is not None:
            device._raise_if_not_live()
            device.mirror.tap(hit['x'], hit['y'])
            ios._sleep(.8)
            return name
        ios._sleep(.25)
    raise ValueError('Spotlight did not confirm the exact query and one app result. No app was opened.')


def install_phone_unicode_launch_compat(ios, package_version):
    """Verify WeChat/Unicode app selection; keep other ASCII launches unchanged."""
    if package_version != '0.3.2':
        return False
    original = ios.IPhone._apps_launch
    if getattr(original, '_telos_unicode_launch', False):
        return True

    @functools.wraps(original)
    def launch(self, name):
        if (not isinstance(name, str)
                or (name.isascii() and _spotlight_text(name) != 'wechat')):
            return original(self, name)
        return _launch_verified_spotlight(self, name, ios)

    launch._telos_unicode_launch = True
    ios.IPhone._apps_launch = launch
    return True


def install_phone_runner(plugin):
    """Keep the official handler and approvals; bootstrap its fresh interpreter."""
    original = getattr(plugin, '_command', None)
    if not callable(original):
        return False
    if getattr(original, '_telos_phone_runner', False):
        return True
    runner = str(Path(__file__).resolve())

    @functools.wraps(original)
    def command():
        upstream = original()
        if upstream is None:
            return None
        if upstream != [sys.executable, '-m', 'phone_harness.run']:
            raise ValueError('Unexpected phone runner entry point.')
        return [sys.executable, runner, '--phone-runner']

    command._telos_phone_runner = True
    plugin._command = command
    return True


def run_phone_runner():
    """Trusted child bootstrap; execute the original script unchanged on stdin."""
    import runpy
    from importlib.metadata import version
    if version('phone-harness') == '0.3.2':
        from phone_harness import mirror, ocr, ios
        install_mirror_chrome_compat(mirror, '0.3.2')
        install_phone_ocr_compat(ocr, '0.3.2')
        install_phone_unicode_launch_compat(ios, '0.3.2')
    sys.argv = ['phone_harness.run']
    runpy.run_module('phone_harness.run', run_name='__main__')


def _new_screenshot_bytes(source, workspace, started):
    """Open beneath one allowed root, refusing symlink components and stale files."""
    source = Path(source)
    if not source.is_absolute() or '..' in source.parts:
        raise ValueError('Screenshot must have an absolute trusted path.')
    if source.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.webp'}:
        raise ValueError('Screenshot must be a PNG, JPEG or WebP image.')
    chosen = None
    for root in (workspace, Path(tempfile.gettempdir()) / 'phone-harness'):
        if root.is_symlink():
            continue
        for prefix in (root.absolute(), root.resolve()):
            try:
                relative = source.relative_to(prefix)
            except ValueError:
                continue
            if relative.parts:
                chosen = root.absolute(), relative.parts
                break
        if chosen:
            break
    if chosen is None:
        raise ValueError('Screenshot is outside this task and the phone-harness temporary folder.')
    root, parts = chosen
    with contextlib.ExitStack() as opened:
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        opened.callback(os.close, directory)
        for part in parts[:-1]:
            directory = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            opened.callback(os.close, directory)
        descriptor = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        opened.callback(os.close, descriptor)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError('Screenshot is not a regular file.')
        if info.st_mtime_ns < int(started * 1_000_000_000):
            raise ValueError('Screenshot was not generated during this phone call. Take a fresh screenshot.')
        if not 0 < info.st_size <= 12_000_000:
            raise ValueError('Screenshot exceeds the task image size limit.')
        with os.fdopen(os.dup(descriptor), 'rb') as file:
            data = file.read(12_000_001)
        if len(data) > 12_000_000:
            raise ValueError('Screenshot exceeds the task image size limit.')
        after = os.fstat(descriptor)
        if (info.st_size, info.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError('Screenshot changed while being imported. Take a fresh screenshot.')
    return data


def import_task_screenshot(source, workspace, started):
    """Copy a verified fresh phone image into the existing inspect_image boundary."""
    from PIL import Image
    workspace = Path(workspace)
    if workspace.is_symlink():
        raise ValueError('The task image directory must not be a symlink.')
    data = _new_screenshot_bytes(source, workspace, started)
    with Image.open(io.BytesIO(data)) as image:
        suffix = {'PNG': '.png', 'JPEG': '.jpg', 'WEBP': '.webp'}.get(image.format)
        width, height = image.size
        if suffix is None or width < 1 or height < 1 or width * height > 40_000_000:
            raise ValueError('Screenshot has an unsupported image format or dimensions.')
        image.load()
    workspace.mkdir(parents=True, exist_ok=True)
    directory = os.open(workspace, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    name = 'phone-' + uuid.uuid4().hex + suffix
    try:
        descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=directory)
        try:
            with os.fdopen(descriptor, 'wb') as file:
                file.write(data)
        except BaseException:
            os.unlink(name, dir_fd=directory)
            raise
    finally:
        os.close(directory)
    return {'name': name, 'width': width, 'height': height,
            'coordinate_space': 'full_image_pixels',
            'hint': f'Inspect with inspect_image(name="{name}"). For this full image use '
                    f'tap_image_point(x, y, image_size=({width}, {height})); tap() expects global Mac '
                    'screen points. Do not reuse coordinates from resized or cropped images.'}


def _summary_object(summary):
    if not isinstance(summary, str):
        return None, ''
    try:
        text = summary.lstrip()
        value, end = json.JSONDecoder().raw_decode(text)
        return (value, text[end:]) if isinstance(value, dict) else (None, '')
    except (ValueError, TypeError):
        return None, ''


def normalize_phone_images(result, workspace, started):
    """Add task-relative image handles, preserving the official result and pixels."""
    if isinstance(result, str):
        try:
            payload = json.loads(result)
        except ValueError:
            return result
        if not isinstance(payload, dict):
            return result
        outer = payload
    elif isinstance(result, dict):
        outer = result
        payload, _ = _summary_object(outer.get('text_summary')) if outer.get('_multimodal') else (outer, '')
        payload = payload or {}
    else:
        return result
    paths = []
    screenshots = payload.get('screenshots')
    if isinstance(screenshots, list):
        paths.extend(path for path in screenshots if isinstance(path, str))
    if payload is not outer and isinstance(outer.get('screenshots'), list):
        paths.extend(path for path in outer['screenshots'] if isinstance(path, str))
    metadata = outer.get('meta')
    if isinstance(metadata, dict) and isinstance(metadata.get('screenshot_path'), str):
        paths.append(metadata['screenshot_path'])
    if not paths:
        return result
    images, errors = [], []
    for source in dict.fromkeys(paths):
        try:
            images.append(import_task_screenshot(source, workspace, started))
        except ValueError as exc:
            errors.append(str(exc))
        except Exception:
            errors.append('Screenshot could not be safely imported. Take a fresh screenshot.')
    additions = {'task_images': images}
    if errors:
        additions['image_import_errors'] = errors
    if isinstance(result, str):
        return json.dumps({**payload, **additions}, ensure_ascii=False)
    updated = {**outer, **additions}
    if outer.get('_multimodal'):
        old_summary = outer.get('text_summary', '')
        summary_payload, suffix = _summary_object(old_summary)
        if summary_payload is not None:
            new_summary = json.dumps({**summary_payload, **additions}, ensure_ascii=False) + suffix
        else:
            # A future upstream prose summary must survive without being parsed.
            prefix = old_summary + '\n\n' if isinstance(old_summary, str) and old_summary else ''
            new_summary = prefix + json.dumps(additions, ensure_ascii=False)
        updated['text_summary'] = new_summary
        updated['meta'] = {**(metadata if isinstance(metadata, dict) else {}), **additions}
        blocks, replaced = [], False
        content = outer.get('content', [])
        if not isinstance(content, list):
            return updated
        for block in content:
            text = block.get('text') if isinstance(block, dict) and block.get('type') == 'text' else None
            if (isinstance(old_summary, str) and old_summary and isinstance(text, str)
                    and (text == old_summary or text.startswith(old_summary + '\n'))):
                blocks.append({**block, 'text': new_summary + text[len(old_summary):]})
                replaced = True
            else:
                blocks.append(block)
        if not replaced:
            blocks.append({'type': 'text', 'text': json.dumps(additions, ensure_ascii=False)})
        updated['content'] = blocks
    return updated


def bundled_phone_plugin():
    """Only the signed app's sibling Runtime; never cwd/project plugin paths."""
    source = Path(__file__).resolve().parent.parent / 'Runtime/plugins' / PLUGIN
    if not source.is_dir():
        return None
    for name, expected in _BUNDLED_FILES.items():
        path = source / name
        if (path.is_symlink() or not path.is_file()
                or hashlib.sha256(path.read_bytes()).hexdigest() != expected):
            raise ValueError('The bundled phone plugin does not match the reviewed version.')
    # The package intentionally carries only these three public source files.
    if {path.name for path in source.iterdir()} - set(_BUNDLED_FILES) - {'__pycache__'}:
        raise ValueError('The bundled phone plugin contains unexpected files.')
    return source


def _mapping(path):
    import yaml
    if not path.is_file():
        return {}
    value = yaml.safe_load(path.read_text())
    return value if isinstance(value, dict) else {}


def _remove(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def prepare_phone_home(data, home, *, feed=False):
    """Inherit only the explicitly enabled shared phone plugin, never credentials.

Run before importing run_agent/model_tools: Hermes discovers plugins at import.
An existing task follows later shared enable/disable changes on its next turn.
"""
    import yaml
    data, home = Path(data), Path(home)
    shared = data / 'hermes'
    source = shared / 'plugins' / PLUGIN
    shared_config = _mapping(shared / 'config.yaml')
    shared_plugins = shared_config.get('plugins') or {}
    if not isinstance(shared_plugins, dict):
        shared_plugins = {}
    enabled = shared_plugins.get('enabled')
    disabled = shared_plugins.get('disabled')
    metadata = shared / 'plugins' / '.install-metadata.json'
    records = json.loads(metadata.read_text()) if metadata.is_file() else {}
    record = records.get(PLUGIN) if isinstance(records, dict) else None
    active = (not feed and isinstance(enabled, list) and PLUGIN in enabled
              and not (isinstance(disabled, list) and PLUGIN in disabled)
              and (source / 'plugin.yaml').is_file()
              and (source / '__init__.py').is_file())
    # Fresh self-contained app installs already include the reviewed source.
    # Explicit shared choices (including uninstall provenance) always win.
    shared_entries = shared_plugins.get('entries')
    explicit_choice = (isinstance(enabled, list)
                       or isinstance(disabled, list) and PLUGIN in disabled
                       or isinstance(records, dict) and PLUGIN in records
                       or isinstance(shared_entries, dict) and PLUGIN in shared_entries)
    if not feed and not (source.exists() or source.is_symlink()) and not explicit_choice:
        bundled = bundled_phone_plugin()
        if bundled is not None:
            source, active = bundled, True
    home.mkdir(parents=True, exist_ok=True)
    plugins_dir = home / 'plugins'
    plugins_dir.mkdir(exist_ok=True)
    target = plugins_dir / PLUGIN
    if active:
        # Do not follow a plugin symlink into credentials or another project.
        root = source.resolve()
        for item in source.rglob('*'):
            if item.is_symlink() and not item.resolve().is_relative_to(root):
                raise ValueError('The phone plugin contains an external symlink.')
        staged = Path(tempfile.mkdtemp(prefix='.phone-install-', dir=plugins_dir))
        old = plugins_dir / ('.phone-old-' + staged.name.rsplit('-', 1)[-1])
        try:
            shutil.copytree(source, staged, dirs_exist_ok=True,
                            ignore=shutil.ignore_patterns('.git', '__pycache__', '*.pyc'))
            if target.exists() or target.is_symlink():
                target.rename(old)
            try:
                staged.rename(target)
            except BaseException:
                if old.exists() or old.is_symlink():
                    old.rename(target)
                raise
        finally:
            _remove(staged)
            _remove(old)
    else:
        _remove(target)

    # Preserve installer provenance without importing unrelated plugin records.
    task_metadata = plugins_dir / '.install-metadata.json'
    if active and isinstance(record, dict):
        task_metadata.write_text(json.dumps({PLUGIN: record}, indent=2) + '\n')
        task_metadata.chmod(0o600)
    elif task_metadata.exists():
        task_metadata.unlink()

    config_path = home / 'config.yaml'
    config = _mapping(config_path)
    entries = shared_plugins.get('entries') or {}
    entry = entries.get(PLUGIN, {}) if isinstance(entries, dict) else {}
    config['plugins'] = {'enabled': [PLUGIN] if active else [],
                         'disabled': [] if active else [PLUGIN],
                         'entries': {PLUGIN: copy.deepcopy(entry)} if active and isinstance(entry, dict) else {}}
    # The native launcher's execution policy is applied by ApprovalGate. Never
    # map it to Hermes yolo/off, and never import another profile's allowlists.
    approvals = config.get('approvals')
    if not isinstance(approvals, dict):
        approvals = config['approvals'] = {}
    approvals['mode'] = 'manual'
    config_path.write_text(yaml.safe_dump(config))
    config_path.chmod(0o600)
    if active:
        os.environ['PHONE_HARNESS_PLATFORM'] = 'ios'
        os.environ['PHONE_HARNESS_TELEMETRY'] = '0'
        os.environ['PHONE_HARNESS_CLASSIFIER_AUTO_RUN'] = '0'
        os.environ['PH_AGENT_WORKSPACE'] = str(home / 'plugin-data' / PLUGIN / 'agent-workspace')
    return active


class PhoneBusy(Exception):
    pass


class PhoneCancelled(Exception):
    pass


class PhoneBridge:
    def __init__(self, data, task_dir, gate, emit, *, enabled=True, lock_timeout=120):
        self.data, self.task_dir = Path(data), Path(task_dir)
        self.gate, self.emit = gate, emit
        self.enabled = enabled
        self.lock_timeout = lock_timeout
        self.cancelled = threading.Event()
        self.denied = False
        self._args = contextvars.ContextVar('telos_phone_args', default=None)
        self._registration = None
        self._skill_registration = None

    def cancel(self):
        self.cancelled.set()

    def _check(self):
        if self.cancelled.is_set():
            raise PhoneCancelled('Phone operation was cancelled. Stop this operation.')
        if self.denied:
            raise PhoneCancelled('Phone operation was not approved. Stop this operation.')

    @contextlib.contextmanager
    def exclusive(self):
        """One physical iPhone across all Telos task processes; release on exit."""
        self._check()
        folder = self.data / 'hermes' / 'plugin-data' / PLUGIN
        folder.mkdir(parents=True, exist_ok=True)
        fd = os.open(folder / 'phone.lock', os.O_CREAT | os.O_RDWR, 0o600)
        acquired = False
        try:
            end = time.monotonic() + self.lock_timeout
            while not acquired:
                self._check()
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    acquired = True
                except BlockingIOError:
                    if time.monotonic() >= end:
                        raise PhoneBusy('Your iPhone is busy with another Telos task. Try again when it finishes.')
                    self.cancelled.wait(min(.1, max(0, end - time.monotonic())))
            self._check()
            yield
        finally:
            if acquired:
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def approve(self, command, description, **_kwargs):
        """Hermes callback: display the complete immutable Python, never CLI input."""
        args = self._args.get()
        if command != '<phone_exec> (plugin approval rule)' or not isinstance(args, dict):
            return 'deny'
        try:
            self._check()
            action = {'app': 'iPhone Mirroring', 'kind': 'python',
                      'reason': '在 iPhone 镜像中执行以下操作',
                      'source': args.get('code', ''), 'timeout_s': args.get('timeout_s', 300)}
            exact = self.gate.ask(action, {'task_id': self.task_dir.name,
                                          'tool': TOOL, 'platform': 'ios'})
            self._check()
            if exact != action:
                self.denied = True
                return 'deny'
            return 'once'
        except Exception:
            self.denied = True
            return 'deny'

    @staticmethod
    def _blocked(message):
        return json.dumps({'success': False, 'error': message}, ensure_ascii=False)

    def middleware(self, *, tool_name, args, next_call, **_kwargs):
        if tool_name != TOOL:
            from phone_skills import phone_skill_args
            return next_call(phone_skill_args(tool_name, args, enabled=self.enabled))
        if not self.enabled:
            return self._blocked('Phone control is disabled for this task.')
        # Imports are lazy so deterministic tests do not need the full runtime.
        try:
            self._check()
            from tools.approval_context import set_hermes_interactive_context, reset_hermes_interactive_context
            from tools.terminal_tool import _get_approval_callback, set_approval_callback
            exact_args = copy.deepcopy(args)
            with self.exclusive():
                token = self._args.set(exact_args)
                previous = _get_approval_callback()
                interactive = set_hermes_interactive_context(True)
                set_approval_callback(self.approve)
                try:
                    # next_call includes the unchanged upstream pre_tool_call
                    # approval hook, then the unchanged phone_exec handler.
                    started = time.time()
                    result = next_call(exact_args)
                    try:
                        return normalize_phone_images(result, self.task_dir / 'files', started)
                    except Exception:
                        # The phone action already ran: an image adapter failure
                        # must never report a failed action and encourage a retry.
                        return result
                finally:
                    set_approval_callback(previous)
                    reset_hermes_interactive_context(interactive)
                    self._args.reset(token)
        except (PhoneBusy, PhoneCancelled) as exc:
            return self._blocked(str(exc))
        except Exception:
            # Hermes middleware skips an exception-raising adapter. Return a
            # failure instead: adapter errors must never invoke the phone.
            return self._blocked('Phone control could not start safely. Please retry the task.')

    def attach(self):
        if not self.enabled:
            return False
        from hermes_cli.plugins import discover_plugins, get_plugin_manager, PluginContext
        from tools.registry import registry
        discover_plugins()
        manager = get_plugin_manager()
        loaded = manager._plugins.get(PLUGIN)
        entry = registry.get_entry(TOOL)
        if not loaded or not loaded.enabled or not entry or entry.toolset != PLUGIN:
            self.enabled = False
            return False
        if not install_phone_runner(loaded.module):
            self.enabled = False
            return False
        context = PluginContext(loaded.manifest, manager)
        from phone_skills import register_phone_skill
        self._skill_registration = register_phone_skill(context)
        self._registration = context.register_middleware('tool_execution', self.middleware)
        return True

    def toolsets(self, *, feed=False):
        return ['telos'] if feed else ['telos', 'skills'] + ([PLUGIN] if self.enabled else [])


if __name__ == '__main__':
    if sys.argv[1:] != ['--phone-runner']:
        raise SystemExit('This is Telos\'s internal phone runner.')
    run_phone_runner()
