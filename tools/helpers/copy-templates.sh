#!/usr/bin/env bash

# Copyright (C) 2019 Christoph Gorgulla
#
# This file is part of VirtualFlow.
#
# VirtualFlow is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# VirtualFlow is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with VirtualFlow.  If not, see <https://www.gnu.org/licenses/>.

# Displaying help if the first argument is -h
usage="Usage: . copy-templates templates [quiet]"
if [ "${1}" = "-h" ]; then
    echo "${usage}"
    return
fi

# Standard error response
error_response_nonstd() {
    echo "Error was trapped which is a nonstandard error."
    echo "Error in bash script $(basename ${BASH_SOURCE[0]})"
    echo "Error on line $1"
    exit 1
}
trap 'error_response_nonstd $LINENO' ERR

# Variables
if [ -f ../../workflow/control/all.ctrl ]; then
    controlfile="../../workflow/control/all.ctrl"
else
    controlfile="../templates/all.ctrl"
fi
central_todo_list_splitting_size="$(grep -m 1 "^central_todo_list_splitting_size=" ${controlfile} | tr -d '[[:space:]]' | awk -F '[=#]' '{print $2}')"


# Copying the template files
if [[ "${1}" = "subjobfiles" || "${1}" = "all" ]]; then
    cp ../templates/one-step.sh ../../workflow/job-files/sub/
    cp ../templates/one-queue.sh ../../workflow/job-files/sub/
    chmod u+x ../../workflow/job-files/sub/one-step.sh
fi
if [[ "${1}" = "todofiles" || "${1}" = "all" ]]; then
    split -a 4 -d -l ${central_todo_list_splitting_size} ../templates/todo.all ../../workflow/ligand-collections/todo/todo.all.
    cp ../../workflow/ligand-collections/todo/todo.all.[0-9]* ../../workflow/ligand-collections/var/
    cp ../templates/todo.all ../../workflow/ligand-collections/var/todo.original
    ln -s todo.all.0000 ../../workflow/ligand-collections/todo/todo.all
fi
if [[ "${1}" = "controlfiles" || "${1}" = "all" ]]; then
    cp ../templates/all.ctrl ../../workflow/control/
fi

# Displaying some information
if [[ ! "$*" = *"quiet"* ]]; then
    echo
    echo "The templates were copied."
    echo
fi
