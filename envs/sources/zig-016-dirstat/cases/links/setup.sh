set -e
mkdir -p root/real/deep
printf 'abcdef' > root/real/deep/a.txt
ln -s real root/alias
ln -s real/deep/a.txt root/a-link.txt
ln -s /nonexistent root/dangling
