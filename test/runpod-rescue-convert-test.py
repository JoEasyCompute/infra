#!/usr/bin/env python3
"""Host-independent tests; never mount, format, resize, or contact a host."""
import json
import pathlib
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'install/runpod-storage-rescue-convert.sh'

class RescueTests(unittest.TestCase):
    def run_function(self, body):
        return subprocess.run(['bash', '-c', 'set -euo pipefail\nsource "$1"\n' + body, '_', str(SCRIPT)], capture_output=True, text=True)

    def test_script_has_safe_help(self):
        result = subprocess.run(['bash', str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--apply', result.stdout)
        self.assertIn('rescue', result.stdout)

    def test_mounted_root_refused(self):
        result = self.run_function('''
ROOT_LV=/dev/mock/root
lsblk() { echo /; }
assert_offline
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mounted', result.stderr)

    def test_fsck_corrected_errors_allowed(self):
        result = self.run_function('e2fsck() { return 1; }; check_ext4 /dev/mock/root')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_fsck_uncorrected_errors_refused(self):
        result = self.run_function('e2fsck() { return 4; }; check_ext4 /dev/mock/root')
        self.assertNotEqual(result.returncode, 0)

    def test_backup_mismatch_refused(self):
        result = self.run_function('rsync() { echo ">f.s....... changed-file"; }; verify_copy /mock/source /mock/backup')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('verification', result.stderr)

    def test_failed_backup_scan_refused(self):
        result = self.run_function('rsync() { return 23; }; verify_copy /mock/source /mock/backup')
        self.assertNotEqual(result.returncode, 0)

    def test_identical_copy_accepted(self):
        result = self.run_function('rsync() { :; }; verify_copy /mock/source /mock/backup')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_backup_must_be_independent_physical_disk(self):
        for scenario in ('independent', 'same_disk', 'loop', 'empty'):
            with self.subTest(scenario=scenario):
                body = r'''
lsblk() {
    if [[ "$*" == *TYPE* ]]; then
        if [[ "$scenario" == loop ]]; then printf 'loop\ndisk\n'; else echo disk; fi
    elif [[ "$scenario" == empty ]]; then :
    elif [[ "${!#}" == root ]]; then printf '253:0\n259:0\n'
    elif [[ "$scenario" == same_disk ]]; then printf '253:1\n259:0\n'
    else printf '8:1\n8:0\n'; fi
}
assert_independent_devices root backup
'''
                result = self.run_function('scenario=' + scenario + '\n' + body)
                self.assertEqual(result.returncode == 0, scenario == 'independent', result.stderr)

    def test_root_space_checked_without_deleting_image(self):
        result = self.run_function(r'''
df() { printf 'Used\n600000000000\n'; }
stat() { if [[ "$*" == *%b* ]]; then echo 100; else echo 1; fi; }
assert_root_fits_without_image /mock/root /mock/image
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Image is preserved', result.stderr)

    def test_shrink_failures_prevent_lv_reduction(self):
        for scenario in ('resize_failure', 'fsck_failure', 'too_large', 'success'):
            with self.subTest(scenario=scenario):
                result = self.run_function('scenario=' + scenario + r'''
ROOT_LV=/dev/mock/root
assert_offline() { :; }
e2fsck() { if [[ "$scenario" == fsck_failure ]]; then return 4; fi; }
resize2fs() { echo RESIZE; if [[ "$scenario" == resize_failure ]]; then return 1; fi; }
dumpe2fs() {
    if [[ "$scenario" == too_large ]]; then echo 'Block count: 200000000'; else echo 'Block count: 130809856'; fi
    echo 'Block size: 4096'
}
lvreduce() { echo REDUCE; }
shrink_root
''')
                self.assertEqual(result.returncode == 0, scenario == 'success', result.stderr)
                self.assertEqual('REDUCE' in result.stdout, scenario == 'success')

    def test_failed_cleanup_unmount_is_failure(self):
        result = self.run_function(r'''
DOCKER_MNT=/mock/docker
mountpoint() { return 0; }
umount() { return 1; }
cleanup
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Could not unmount', result.stderr)

    def test_config_preserves_root_and_nvidia(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / 'etc/docker').mkdir(parents=True)
            (root / 'etc/fstab').write_text('UUID=root / ext4 defaults 0 1\nUUID=efi /boot/efi vfat defaults 0 1\n/var/lib/container-runtime.img /var/lib/docker xfs loop,nofail 0 0\n/var/lib/docker/containerd /var/lib/containerd none bind,nofail 0 0\n')
            original = {'runtimes': {'nvidia': {'path': 'nvidia-container-runtime'}}, 'userns-remap': 'default', 'live-restore': True}
            (root / 'etc/docker/daemon.json').write_text(json.dumps(original))
            result = self.run_function(f'patch_boot_config "{root}" test-docker-uuid')
            self.assertEqual(result.returncode, 0, result.stderr)
            cfg = json.loads((root / 'etc/docker/daemon.json').read_text())
            self.assertEqual(cfg, dict(original, **{'data-root': '/var/lib/docker'}))
            fstab = (root / 'etc/fstab').read_text()
            self.assertIn('UUID=root / ext4 defaults 0 1', fstab)
            self.assertIn('UUID=efi /boot/efi vfat defaults 0 1', fstab)
            self.assertNotIn('container-runtime.img', fstab)
            self.assertIn('UUID=test-docker-uuid /var/lib/docker xfs defaults,noatime,prjquota,nofail 0 0', fstab)
            self.assertEqual(fstab.count('/var/lib/docker/containerd /var/lib/containerd'), 1)

if __name__ == '__main__':
    unittest.main()
