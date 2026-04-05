MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"
export PYTHONPATH="${MYDIR}/..:${PYTHONPATH}"

for i in {1..10}
do
		python3 "${MYDIR}/stabilize_lock.py" ${i} > "${MYDIR}/stabilize_lock/stabilize_lock_${i}.sgrk"
done
