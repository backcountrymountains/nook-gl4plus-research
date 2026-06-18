#!/usr/bin/env bash
# Find types in the vendor CIL policy that:
# 1. Are associated with sysfs (have fs_type or sysfs_type attributes)
# 2. Look unused, test, factory, or vendor-specific

CIL=/tmp/nonplat_sepolicy.cil
PLAT_CIL=/tmp/plat_sepolicy.cil
FILE_CTX=/tmp/nonplat_file_contexts
PLAT_FILE_CTX=/tmp/plat_file_contexts

echo "=== sysfs-typed entries in nonplat_file_contexts ==="
grep "sysfs" "$FILE_CTX"

echo ""
echo "=== sysfs-typed entries in plat_file_contexts ==="
grep "sysfs" "$PLAT_FILE_CTX"

echo ""
echo "=== Types with sysfs_type attribute in nonplat CIL ==="
grep -i "sysfs_type\|sysfs_fs_type" "$CIL" | grep "typeattributeset"

echo ""
echo "=== Types with sysfs_type attribute in plat CIL ==="
grep -i "sysfs_type\|sysfs_fs_type" "$PLAT_CIL" | grep "typeattributeset"

echo ""
echo "=== Candidate types: vendor/test/factory/disp/epd/eink/sunxi/allwinner in nonplat CIL ==="
grep -i "test\|factory\|disp\|epd\|eink\|sunxi\|allwinner\|waveform\|vendor_test\|debug" "$CIL" | grep "^(type " | head -40

echo ""
echo "=== All sysfs-related type declarations in nonplat CIL ==="
grep "^(type sysfs" "$CIL" | head -40
