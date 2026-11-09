EFIINC = /usr/include/efi
EFILIB = /usr/lib

CFLAGS = -I$(EFIINC) -I$(EFIINC)/x86_64 -DEFI_FUNCTION_WRAPPER \
         -fpic -ffreestanding -fno-stack-protector -fshort-wchar \
         -mno-red-zone -maccumulate-outgoing-args -Wall -O2

all: loader.efi

loader.o: loader.c
	gcc $(CFLAGS) -c $< -o $@

loader.so: loader.o
	ld -shared -Bsymbolic -L$(EFILIB) -T $(EFILIB)/elf_x86_64_efi.lds \
	   $(EFILIB)/crt0-efi-x86_64.o $< -o $@ -lefi -lgnuefi

loader.efi: loader.so
	objcopy -j .text -j .sdata -j .data -j .rodata -j .dynamic -j .dynsym \
	        -j .rel -j .rela -j '.rel.*' -j '.rela.*' -j .reloc \
	        --target efi-app-x86_64 --subsystem=10 $< $@

clean:
	rm -f loader.o loader.so loader.efi
