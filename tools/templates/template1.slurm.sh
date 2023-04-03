#!/bin/bash
# Copyright (C) 2019 Christoph Gorgulla
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# This file is part of VirtualFlow.
#
# VirtualFlow is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# VirtualFlow is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VirtualFlow.  If not, see <https://www.gnu.org/licenses/>.

# ---------------------------------------------------------------------------
#
# Description: Slurm job file.
#
# Revision history:
# 2022-07-21  Original version
#
# ---------------------------------------------------------------------------

# Update the SBATCH section if needed for your particular Slurm
# installation. If a line starts with "##" (two #s) it will be 
# ignored

#SBATCH --job-name={{job_letter}}-{{workunit_id}}
#SBATCH --array {{array_start}}-{{array_end}}%{{slurm_array_job_throttle}}
##SBATCH --time=00-12:00:00
##SBATCH --mem-per-cpu=800M
##SBATCH --nodes=1
#SBATCH --cpus-per-task={{slurm_cpus}}
##SBATCH --partition={{slurm_partition}}
#SBATCH --output={{batch_workunit_base}}/%A_%a.out
#SBATCH --error={{batch_workunit_base}}/%A_%a.err
#SBATCH --account={{slurm_account}}


# If you are using a virtualenv, make sure the correct one 
# is being activated

source $HOME/vflp_env/bin/activate

# Load modules (if needed, depends on cluster configuration)
module load openbabel/3.3.1
module load java

# deletes the temp directory
function cleanup {
  rm -rf ${VFLP_PKG_TMP_DIR}
  echo "delete tmpdir ${VFLP_PKG_TMP_DIR}"
}

trap cleanup EXIT


# Job Information -- generally nothing in this
# section should be changed
##################################################################################

export VFLP_WORKUNIT={{workunit_id}}
export VFLP_JOB_STORAGE_MODE={{job_storage_mode}}
export VFLP_WORKUNIT_SUBJOB=$SLURM_ARRAY_TASK_ID
export VFLP_VCPUS=${SLURM_CPUS_PER_TASK}
export VFLP_RUN_SEQUENTIAL=0

##################################################################################

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
