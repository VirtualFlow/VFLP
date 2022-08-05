#!/usr/bin/env bash

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

echo "Running AWS Batch"

error_response_std() {

    # Printint some information
    echo "Error was trapped" 1>&2
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})" 1>&2
    echo "Error on line $1" 1>&2
    echo "Environment variables" 1>&2
    echo "----------------------------------" 1>&2
    env 1>&2

    # Exiting
    exit 1
}
trap 'error_response_std $LINENO' ERR

# Adjusting the CHEMAXON_LICENSE_URL environment variable
VFLP_PKG_BASE=/opt/vf/packages
export CHEMAXON_LICENSE_URL="${VFLP_PKG_BASE}/chemaxon/license.cxl"
export CLASSPATH="${VFLP_PKG_BASE}/nailgun/nailgun-server/target/classes:${VFLP_PKG_BASE}/nailgun/nailgun-examples/target/classes:${VFLP_PKG_BASE}/jchemsuite/lib/*"
export PATH="${VFLP_PKG_BASE}/nailgun/nailgun-client/target/:$PATH"

export VFLP_WORKUNIT_SUBJOB=${AWS_BATCH_JOB_ARRAY_INDEX}

env

cd /opt/vf/tools
./vflp_run.py


