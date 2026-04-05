MYSELF=$(realpath "$0")
MYDIR="${MYSELF%/*}"

PREFIX=$1
CATEGORY=${2:-R2R}

for file in "${MYDIR}/${CATEGORY}/${PREFIX}/${PREFIX}"*.sgrk
do
    python3 "${MYDIR}/to_strix.py" "${file}" > "${file}.strix"
done
