MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
export PYTHONPATH="${MYDIR}/..:${PYTHONPATH}"

for i in {1..10}
do
	python3 "${MYDIR}/responsive_toggle.py" ${i} > "${MYDIR}/responsive_toggle/responsive_toggle_${i}.sgrk"
done
