# otikoboot

A tiny UEFI bootloader for Linux, written in C with gnu-efi. It loads a
kernel that has the **EFI stub** (`CONFIG_EFI_STUB`), hands it a command line,
and starts it. The stub then loads the initrd itself through `initrd=`.

It is about 100 lines, it has no menu, and it is not a GRUB replacement. It is
a learning project that boots a real kernel.

> **Tested on exactly one machine:** Zorin OS 18.1, x86_64 UEFI, kernels
> 6.17.0-20 and 7.0.0-42, root on ext4 on an NVMe drive. Anything else is
> untested.

## Read this before you run anything

**`loader.c` has values hardcoded for the author's machine. They will not work
on yours until you change them.**

```c
#define KERNEL_PATH  L"\\EFI\\otiko\\vmlinuz"

static CHAR16 default_cmdline[] =
    L"root=/dev/nvme0n1p2 ro quiet splash "
    L"initrd=\\EFI\\otiko\\initrd.img";
```

- `root=/dev/nvme0n1p2` is **the author's root partition**. Replace it with
  yours. Find it with:
  ```sh
  findmnt -no SOURCE /          # e.g. /dev/sda3
  sudo blkid -s UUID -o value /dev/sda3   # for root=UUID=... instead
  ```
  A `root=UUID=...` value survives disks being renumbered. A device path like
  `/dev/nvme0n1p2` does not.
- `initrd=` must name the initrd file you copy to the ESP. Ubuntu-family
  systems call it `initrd.img-<version>`, Arch-family systems
  `initramfs-linux.img`. The name in `loader.c` and the file on the ESP have to
  match.
- If your root is on LUKS or LVM, copy the working arguments from
  `cat /proc/cmdline` on a booted system instead of writing your own.

`setup.sh` is also machine-specific. It uses `apt`, expects Debian/Ubuntu
kernel names, and **refuses to run unless root is `/dev/nvme0n1p2`** (the
`EXPECT_ROOT` variable at the top). Edit that variable, or skip the script and
follow the manual steps below.

## What you need

- x86_64 machine booted in UEFI mode
- a kernel built with `CONFIG_EFI_STUB` (stock Ubuntu, Debian, Fedora and Arch
  kernels are)
- `gcc`, `make`, `gnu-efi`, `efibootmgr`
  - Debian/Ubuntu: `sudo apt install gnu-efi build-essential efibootmgr`
  - Arch/Artix: `sudo pacman -S gnu-efi base-devel efibootmgr`
- **Secure Boot off.** `loader.efi` is unsigned, so firmware with Secure Boot
  enabled will refuse to run it.

## Build

```sh
make
```

This produces `loader.efi`. The `Makefile` expects gnu-efi's `crt0-efi-x86_64.o`
and `elf_x86_64_efi.lds` in `/usr/lib` and its headers in `/usr/include/efi`. If
your distro puts them elsewhere, change `EFILIB` and `EFIINC` at the top.

## Install, manually

UEFI firmware cannot read ext4, so the kernel and initrd have to be copied to
the EFI System Partition (ESP, usually mounted at `/boot/efi`):

```sh
sudo mkdir -p /boot/efi/EFI/otiko
sudo cp /boot/vmlinuz-<version>    /boot/efi/EFI/otiko/vmlinuz
sudo cp /boot/initrd.img-<version> /boot/efi/EFI/otiko/initrd.img
sudo cp loader.efi                 /boot/efi/EFI/otiko/loader.efi
```

Then add a boot entry. `-C` creates it **without** putting it first in the boot
order, so your existing boot method stays the default:

```sh
# find your ESP's disk and partition number
findmnt /boot/efi

sudo efibootmgr -C --disk /dev/<disk> --part <partition-number> \
  --label otikoboot --loader '\EFI\otiko\loader.efi'
```

## Booting it

Pick one:

1. **Firmware boot menu.** Choose `otikoboot` from the one-time boot menu
   (F12, F11, Esc or F9, depending on the vendor).
2. **`BootNext`.** `sudo efibootmgr -n <entry-number>` boots it once on the
   next reboot. Some firmware ignores this.
3. **From GRUB, if the firmware hides the entry.** Add this to
   `/etc/grub.d/40_custom`, then run `update-grub`:
   ```
   menuentry "otikoboot" {
       insmod part_gpt
       insmod fat
       insmod chain
       search --no-floppy --fs-uuid --set=root <ESP-UUID>
       chainloader /EFI/otiko/loader.efi
   }
   ```
   Get the ESP's UUID with `sudo blkid -s UUID -o value <esp-device>`.
4. **Make it the default.** Put it first in `BootOrder` and leave your old
   entry second, so a failure falls through to a working boot:
   ```sh
   sudo efibootmgr -v          # note the current BootOrder first
   sudo efibootmgr -o <otikoboot>,<old-entries...>
   ```

To confirm it was really your loader, check `cat /proc/cmdline` after boot. It
should show your `initrd=\EFI\otiko\initrd.img` argument and no `BOOT_IMAGE=`.

## Passing a different command line

If the boot entry carries load options that contain a `root=` argument, the
loader uses them and ignores the built-in string. That way you can change the
command line without rebuilding:

```sh
sudo efibootmgr -C --disk /dev/<disk> --part <n> --label otikoboot \
  --loader '\EFI\otiko\loader.efi' \
  --unicode 'root=UUID=<uuid> ro quiet initrd=\EFI\otiko\initrd.img'
```

## Things that will bite you

- **The ESP copy goes stale.** When your distro installs a new kernel, the
  `vmlinuz` and `initrd.img` on the ESP stay the old version. Copy them again,
  or add a post-install hook for your package manager.
- **Kernel and modules must match.** The kernel you stage has to be a version
  whose `/lib/modules/<version>` is still installed, or you boot without
  drivers.
- **Only EFI-stub kernels work.** `LoadImage` rejects anything else.
- **Keep a fallback.** Do not remove your normal bootloader until you have
  booted this a few times. A bad entry in the boot order can leave you at the
  firmware screen.
- **No menu, no config file, no multiple entries.** One kernel, one command
  line.

## Uninstall

```sh
sudo efibootmgr                      # find the otikoboot entry number
sudo efibootmgr -B -b <number>
sudo rm -r /boot/efi/EFI/otiko
```

If you added a GRUB entry, remove it from `/etc/grub.d/40_custom` and run
`update-grub`.

## How it works

1. Firmware starts `loader.efi`.
2. It builds a device path for `\EFI\otiko\vmlinuz` on the same volume and
   calls `LoadImage`, which parses the kernel's PE/COFF header.
3. It sets the kernel image's `LoadOptions` to the command line.
4. It calls `StartImage`. The kernel's EFI stub reads the command line,
   loads the initrd named by `initrd=` from the same volume, and boots Linux.

Init systems, initramfs generators and distros do not matter to the loader. It
only passes a command line and starts the image.
