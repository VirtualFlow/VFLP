#!/bin/bash


# deletes the temp directory
function cleanup {
  rm -rf ${VFLP_PKG_TMP_DIR}
  echo "delete tmpdir ${VFLP_PKG_TMP_DIR}"
}

trap cleanup EXIT

export VFLP_JOB_STORAGE_MODE=sharedfs
export VFLP_VCPUS=4
export VFLP_WORKUNIT=1
export VFLP_WORKUNIT_SUBJOB=0
export VFLP_RUN_SEQUENTIAL=0

export VFLP_WORKFLOW_DIR=$(readlink --canonicalize ..)/workflow

export VFLP_CONFIG_JSON=${VFLP_WORKFLOW_DIR}/config.json
export VFLP_WORKUNIT_JSON=${VFLP_WORKFLOW_DIR}/workunits/${VFLP_WORKUNIT}.json.gz

VFLP_PKG_BASE=$(readlink --canonicalize .)/packages
VFLP_PKG_TMP_DIR=$(mktemp -d)

chemaxon_license_filename=$(jq -r .chemaxon_license_filename ${VFLP_CONFIG_JSON})

jchem_package_filename=$(jq -r .jchem_package_filename ${VFLP_CONFIG_JSON})
java_package_filename=$(jq -r .java_package_filename ${VFLP_CONFIG_JSON})
ng_package_filename=$(jq -r .ng_package_filename ${VFLP_CONFIG_JSON})

if [[ "$jchem_package_filename" != "none" ]]; then
	echo "Unpacking $jchem_package_filename to ${VFLP_PKG_TMP_DIR}/jchemsuite"
	tar -xf $VFLP_PKG_BASE/$jchem_package_filename -C ${VFLP_PKG_TMP_DIR}
fi

if [[ "$java_package_filename" != "none" ]]; then
	echo "Unpacking $java_package_filename to ${VFLP_PKG_TMP_DIR}/java"
	tar -xf $VFLP_PKG_BASE/$java_package_filename -C ${VFLP_PKG_TMP_DIR}
	export JAVA_HOME=${VFLP_PKG_TMP_DIR}/java/bin
fi

if [[ "$ng_package_filename" != "none" ]]; then
	echo "Unpacking $ng_package_filename to ${VFLP_PKG_TMP_DIR}/nailgun"
	tar -xf $VFLP_PKG_BASE/$ng_package_filename -C ${VFLP_PKG_TMP_DIR}
fi

if [[ "$chemaxon_license_filename" != "none" ]]; then
	export CHEMAXON_LICENSE_URL=${VFLP_PKG_TMP_DIR}/chemaxon_license_filename
	cp $VFLP_PKG_BASE/$chemaxon_license_filename ${CHEMAXON_LICENSE_URL}
fi

export CLASSPATH="${VFLP_PKG_TMP_DIR}/nailgun/nailgun-server/target/classes:${VFLP_PKG_TMP_DIR}/nailgun/nailgun-examples/target/classes:${VFLP_PKG_TMP_DIR}/jchemsuite/lib/*"
export PATH="${VFLP_PKG_TMP_DIR}/java/bin:${VFLP_PKG_TMP_DIR}/nailgun/nailgun-client/target/:$PATH"

env

./vflp_run.py
