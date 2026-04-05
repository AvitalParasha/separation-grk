MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
export PYTHONPATH="${MYDIR}/..:${PYTHONPATH}"

for i in {1..10}
do
		python3 "${MYDIR}/multi_mode.py" ${i} > "${MYDIR}/multi_mode/multi_mode_${i}.sgrk"
done
