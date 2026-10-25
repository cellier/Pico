"""One user-visible home for Pico outputs, retaining legacy workspace links.

Only workspace files move here. Conversation history, credentials and execution
records stay in Application Support. The native app uses this same lock and
directory layout when it migrates inactive workspaces at startup.
"""
import contextlib
import errno
import fcntl
import os
import stat
import uuid
from pathlib import Path


class GeneratedFilesError(RuntimeError):
    pass


def _data_path(data):
    return Path(data).expanduser().resolve()


def _configured_root(data):
    override = os.environ.get('PICO_FILES_DIR', '').strip()
    if override:
        root = Path(override).expanduser().resolve()
    elif data == (Path.home() / 'Library/Application Support/Telos').resolve():
        root = (Path.home() / 'Documents/Pico').resolve()
    else:
        # Previews and test data never write into the user's real Documents.
        root = data / 'PicoFiles'
    if root == Path(root.anchor) or root == Path.home().resolve():
        raise GeneratedFilesError('Pico files need their own folder, not the home folder or a disk root.')
    return root


def _private_directory(path):
    if path.is_symlink() or (path.exists() and not path.is_dir()):
        raise GeneratedFilesError('Pico files folder is not an ordinary directory: ' + str(path))
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)


@contextlib.contextmanager
def _migration_lock(data):
    data.mkdir(parents=True, exist_ok=True, mode=0o700)
    flags = os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_CLOEXEC', 0)
    try:
        fd = os.open(data / 'generated-files.lock', flags, 0o600)
    except OSError as error:
        raise GeneratedFilesError('Could not safely open the Pico files migration lock.') from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
            raise GeneratedFilesError('Pico files migration lock has an unexpected owner or type.')
        os.fchmod(fd, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def generated_files_root(data):
    """Create and return the physical, private output root for this data store."""
    data = _data_path(data)
    with _migration_lock(data):
        root = _configured_root(data)
        _private_directory(root)
        return root


def _empty(path):
    return next(path.iterdir(), None) is None


def _move_workspace(source, destination):
    # rename is deliberate: never synchronously copy gigabytes or partly move a
    # website when Documents is on another disk. The old tree remains intact.
    if source.stat().st_dev != destination.parent.stat().st_dev:
        raise GeneratedFilesError('Pico files are on different volumes; the original workspace was kept at ' + str(source))
    try:
        os.rename(source, destination)
    except OSError as error:
        if error.errno == errno.EXDEV:
            raise GeneratedFilesError('Pico files are on different volumes; the original workspace was kept at ' + str(source)) from error
        raise


def task_workspace(data, task_id, *, chat=False):
    """Return an actual workspace directory; old absolute paths remain valid.

    Never merge two populated directories or accept a legacy link to an unknown
    location. All migrations (including native startup) serialize on one lock.
    """
    data = _data_path(data)
    identifier = str(uuid.UUID(str(task_id)))
    with _migration_lock(data):
        root = _configured_root(data)
        _private_directory(root)
        category = root / ('Chats' if chat else 'Tasks')
        _private_directory(category)
        destination = category / identifier
        if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
            raise GeneratedFilesError('Pico workspace destination is not an ordinary directory: ' + str(destination))

        legacy_parent = data / ('chats' if chat else 'tasks') / identifier
        legacy = legacy_parent / 'files'
        # The metadata parent must not redirect a migration into another tree.
        for parent in (legacy_parent.parent, legacy_parent):
            if parent.is_symlink() or (parent.exists() and not parent.is_dir()):
                raise GeneratedFilesError('Pico workspace metadata folder is not an ordinary directory: ' + str(parent))
        legacy_parent.mkdir(parents=True, exist_ok=True, mode=0o700)

        if legacy.is_symlink():
            target = (legacy.parent / os.readlink(legacy)).resolve()
            if target != destination:
                raise GeneratedFilesError('Pico workspace link points to an unexpected location: ' + str(legacy))
            _private_directory(destination)
            return destination
        if legacy.exists() and not legacy.is_dir():
            raise GeneratedFilesError('Pico legacy workspace is not a directory: ' + str(legacy))

        moved = removed_empty = removed_destination = False
        if legacy.exists():
            if destination.exists():
                if _empty(legacy):
                    legacy.rmdir()
                    removed_empty = True
                elif _empty(destination):
                    # Check the volume before removing even an empty target.
                    if legacy.stat().st_dev != category.stat().st_dev:
                        raise GeneratedFilesError('Pico files are on different volumes; the original workspace was kept at ' + str(legacy))
                    destination.rmdir()
                    removed_destination = True
                else:
                    raise GeneratedFilesError('Both Pico workspace folders contain files; neither was overwritten: ' + str(legacy))
            if not removed_empty:
                try:
                    _move_workspace(legacy, destination)
                    moved = True
                except BaseException:
                    if removed_destination and not destination.exists():
                        _private_directory(destination)
                    raise
        try:
            _private_directory(destination)
            legacy.symlink_to(destination, target_is_directory=True)
        except BaseException:
            # If the alias cannot be created, restore the original legacy path.
            if moved and not legacy.exists() and not legacy.is_symlink():
                os.rename(destination, legacy)
                if removed_destination:
                    _private_directory(destination)
            elif removed_empty and not legacy.exists() and not legacy.is_symlink():
                legacy.mkdir(mode=0o700)
            raise
        return destination
