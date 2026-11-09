#include <efi.h>
#include <efilib.h>

#define KERNEL_PATH  L"\\EFI\\otiko\\vmlinuz"
#define MAX_OPT_CHARS 4096

/* Fallback cmdline, used when this loader's own boot entry carries no usable options. */
static CHAR16 default_cmdline[] =
    L"root=/dev/nvme0n1p2 ro quiet splash "
    L"initrd=\\EFI\\otiko\\initrd.img";

/*
 * Options handed to THIS loader (LoadedImage->LoadOptions) are optional.
 * The boot entry decides what they are: with
 *   efibootmgr --unicode '<cmdline>'
 * the string is forwarded to the kernel verbatim. Launching from the UEFI shell
 * passes the shell command line instead, which has no root= token, so it falls
 * through to default_cmdline.
 */

/* Copy into a NUL-terminated heap buffer; firmware gives no termination guarantee. */
static CHAR16 *dup_options(VOID *src, UINT32 size)
{
    UINT32 chars, len;
    CHAR16 *buf;

    if (!src || size == 0 || (size % sizeof(CHAR16)) != 0)
        return NULL;
    chars = size / sizeof(CHAR16);
    if (chars > MAX_OPT_CHARS)
        return NULL;
    buf = AllocatePool((chars + 1) * sizeof(CHAR16));
    if (!buf)
        return NULL;
    CopyMem(buf, src, chars * sizeof(CHAR16));
    buf[chars] = 0;

    /* A single trailing NUL inside the reported size is normal (efibootmgr
       stores one); a NUL anywhere earlier means the data isn't a plain string. */
    len = (UINT32)StrLen(buf);
    if (len != chars && len != chars - 1) {
        uefi_call_wrapper(BS->FreePool, 1, buf);
        return NULL;
    }
    return buf;
}

static BOOLEAN is_space(CHAR16 c)
{
    return c == L' ' || c == L'\t' || c == L'\n' || c == L'\r';
}

/* TRUE if some whitespace-delimited token starts with root= and has a non-empty value. Input must be NUL-terminated. */
static BOOLEAN has_root_token(const CHAR16 *p)
{
    while (*p) {
        if (p[0] == L'r' && p[1] == L'o' && p[2] == L'o' && p[3] == L't' &&
            p[4] == L'=' && p[5] != 0 && !is_space(p[5]))
            return TRUE;
        while (*p && !is_space(*p)) p++;   /* skip this token */
        while (is_space(*p)) p++;          /* skip separators */
    }
    return FALSE;
}

static void explain_load_error(EFI_STATUS s)
{
    switch (s) {
    case EFI_NOT_FOUND:
        Print(L"  kernel file not found on the ESP\n"); break;
    case EFI_UNSUPPORTED:
        Print(L"  not a loadable EFI executable for this arch (kernel without EFI stub?)\n"); break;
    case EFI_LOAD_ERROR:
        Print(L"  image corrupt or failed to load\n"); break;
    case EFI_SECURITY_VIOLATION:
        Print(L"  rejected by Secure Boot policy\n"); break;
    case EFI_OUT_OF_RESOURCES:
        Print(L"  out of memory\n"); break;
    default: break;
    }
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *st)
{
    EFI_STATUS s;
    EFI_LOADED_IMAGE *self, *kernel;
    EFI_DEVICE_PATH *dp;
    EFI_HANDLE kimg;
    CHAR16 *heap_opts, *cmd;

    InitializeLib(image, st);
    Print(L"otikoboot: starting\n");

    s = uefi_call_wrapper(BS->HandleProtocol, 3, image,
                          &LoadedImageProtocol, (void **)&self);
    if (EFI_ERROR(s)) { Print(L"self LoadedImage: %r\n", s); return s; }

    dp = FileDevicePath(self->DeviceHandle, KERNEL_PATH);
    if (!dp) { Print(L"FileDevicePath failed\n"); return EFI_OUT_OF_RESOURCES; }

    s = uefi_call_wrapper(BS->LoadImage, 6, FALSE, image, dp, NULL, 0, &kimg);
    uefi_call_wrapper(BS->FreePool, 1, dp);
    if (EFI_ERROR(s)) {
        Print(L"LoadImage(%s): %r\n", KERNEL_PATH, s);
        explain_load_error(s);
        return s;
    }

    s = uefi_call_wrapper(BS->HandleProtocol, 3, kimg,
                          &LoadedImageProtocol, (void **)&kernel);
    if (EFI_ERROR(s)) {
        Print(L"kernel LoadedImage: %r\n", s);
        uefi_call_wrapper(BS->UnloadImage, 1, kimg);   /* loaded but never started */
        return s;
    }

    heap_opts = dup_options(self->LoadOptions, self->LoadOptionsSize);
    cmd = (heap_opts && has_root_token(heap_opts)) ? heap_opts : default_cmdline;

    kernel->LoadOptions = cmd;
    kernel->LoadOptionsSize = (UINT32)((StrLen(cmd) + 1) * sizeof(CHAR16));

    Print(L"otikoboot: cmdline: %s\n", cmd);
    s = uefi_call_wrapper(BS->StartImage, 3, kimg, NULL, NULL);

    /* Applications are unloaded by firmware when they return; no UnloadImage here. */
    Print(L"kernel started but returned: %r\n", s);
    if (heap_opts)
        uefi_call_wrapper(BS->FreePool, 1, heap_opts);
    uefi_call_wrapper(BS->Stall, 1, 5000000);
    return s;
}
