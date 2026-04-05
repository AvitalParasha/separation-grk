MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
export PYTHONPATH="${MYDIR}/..:${PYTHONPATH}"

for i in {1..10}
do
		python3 "${MYDIR}/forced_oscillation.py" ${i} > "${MYDIR}/forced_oscillation/forced_oscillation_${i}.sgrk"
done
