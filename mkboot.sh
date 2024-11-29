cp ./tmp_mkboot/initrd* ./tmp_mkboot/initrd.img
cp ./tmp_mkboot/*.dtb ./tmp_mkboot/dtb
cat ./tmp_mkboot/Image.gz ./tmp_mkboot/dtb > ./tmp_mkboot/kernel-dtb
mkbootimg --base 0x80000000 \
        --kernel_offset 0x00008000 \
        --ramdisk_offset 0x01000000 \
        --tags_offset 0x00000100 \
        --pagesize 2048 \
        --second_offset 0x00f00000 \
        --ramdisk ./tmp_mkboot/initrd.img \
        --cmdline "earlycon console=tty0 root=UUID=cf0a4308-8a5e-4f83-8750-9dfe2bb0e336 rw loglevel=3 splash"\
        --kernel ./tmp_mkboot/kernel-dtb -o ./tmp_mkboot/boot.img
rm ./tmp_mkboot/dtb
rm ./tmp_mkboot/kernel-dtb
rm ./tmp_mkboot/initrd.img
rm ./tmp_mkboot/rootfs.img
img2simg ./root.img ./tmp_mkboot/rootfs.img
