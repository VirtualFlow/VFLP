#!/usr/bin/env python3

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
# Description: Parse the config file and generate the workflow directory
#
# ---------------------------------------------------------------------------


import json
import re
import argparse
from pathlib import Path
import shutil


def parse_config(filename):

    config = {
        'tranche_partitions' : {},
        'tranche_mappings' : {}
    }

    with open(filename, "r") as read_file:
        for index, line in enumerate(read_file):
            #match = re.search(r'^(?P<parameter>.*?)\s*=\s*(?P<parameter_value>.*?)\s*$', line)
            match = re.search(r'^(?P<parameter>[a-zA-Z0-9_]+)\s*=\s*(?P<parameter_value>.*?)\s*$', line)
            if(match):
                matches = match.groupdict()

                # Special handling for partitions
                match_partition = re.search(r'^tranche\_(?P<type>.*?)\_(?P<qualifier>partition|mapping)$', matches['parameter'])
                if(match_partition):
                    matches_partition = match_partition.groupdict()

                    if(matches_partition['qualifier'] == "mapping"):
                        config['tranche_mappings'][matches_partition['type']] = {}
                        for mapping in matches['parameter_value'].split(","):
                            (map_from, map_to) = mapping.split(":")
                            config['tranche_mappings'][matches_partition['type']][map_from] = map_to
                    else:
                        config['tranche_partitions'][matches_partition['type']] = matches['parameter_value'].split(":")
                else:
                    config[matches['parameter']] = matches['parameter_value']

    config['object_store_job_output_data_prefix_full'] = f"{config['object_store_job_output_data_prefix']}/{config['job_name']}"
    config['target_formats'] = config['targetformats'].split(":")
    config['tranche_types'] = config['tranche_types'].split(":")
    config['file_fieldnames'] = config['file_fieldnames'].split(":")
    config['attributes_to_generate'] = config['attributes_to_generate'].split(":")



    timeout_defaults = {
        'chemaxon_neutralization_timeout' : 30,
        'cxcalc_stereoisomer_timeout' : 30,
        'cxcalc_tautomerization_timeout' : 30,
        'cxcalc_protonation_timeout': 30,
        'obabel_protonation_timeout': 30,
        'molconvert_conformation_timeout': 30,
        'obabel_conformation_timeout': 30
    }

    for timeout_key in timeout_defaults:
        if(empty_value(config, timeout_key)):
            print(f"* '{timeout_key}' not set, so setting to default of {timeout_defaults[timeout_key]}")
            config[timeout_key] = timeout_defaults[timeout_key]
        elif(not config[timeout_key].isnumeric()):
            print(f"* '{timeout_key}' not valid, so setting to default of {timeout_defaults[timeout_key]}")
            config[timeout_key] = timeout_defaults[timeout_key]
        else:
            config[timeout_key] = int(config[timeout_key])


    return config


def empty_value(config, value):
    if(value not in config):
        return 1
    elif(config[value] == ""):
        return 1
    else:
        return 0


def check_parameters(config):
    error = 0


    if(not empty_value(config, 'job_letter') and not empty_value(config, 'job_name')):
        print("* Define either job_letter or job_name (job_letter is being deprecated)")
        error = 1

    if(not empty_value(config, 'job_name')):
        config['job_letter'] = config['job_name']

    if(empty_value(config, 'threads_to_use')):
        print("* 'threads_to_use' must be set in all.ctrl")
        error = 1

    if(empty_value(config, 'job_storage_mode') or (config['job_storage_mode'] != "s3" and config['job_storage_mode'] != "sharedfs")):
        print("* 'job_storage_mode' must be set to 's3' or 'sharedfs'")
        error = 1
    else:
        if(config['job_storage_mode'] == "s3"):
            if(empty_value(config, 'object_store_job_output_data_bucket')):
                print("* 'object_store_job_output_data_bucket' must be set if job_storage_mode is 's3'")
                error = 1
            if(empty_value(config, 'object_store_job_output_data_prefix')):
                print("* 'object_store_job_output_data_prefix' must be set if job_storage_mode is 's3'")
                error = 1
            else:
                config['object_store_job_output_data_prefix'].rstrip("/")
            if(empty_value(config, 'object_store_ligand_library_bucket')):
                print("* 'object_store_ligand_library_bucket' must be set if job_storage_mode is 's3'")
                error = 1
            if(empty_value(config, 'object_store_ligand_library_prefix')):
                print("* 'object_store_ligand_library_prefix' must be set if job_storage_mode is 's3'")
                error = 1
            else:
                config['object_store_ligand_library_prefix'].rstrip("/")


    if(empty_value(config, 'batchsystem')):
        print("* 'batchsystem' must be set in all.ctrl")
        error = 1
    else:
        if(config['batchsystem'] == "awsbatch"):
            if(empty_value(config, 'aws_batch_prefix')):
                print("* 'aws_batch_prefix' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_batch_number_of_queues')):
                print("* 'aws_batch_number_of_queues' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_batch_array_job_size')):
                print("* 'aws_batch_array_job_size' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_ecr_repository_name')):
                print("* 'aws_ecr_repository_name' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_region')):
                print("* 'aws_region' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_batch_subjob_vcpus')):
                print("* 'aws_batch_subjob_vcpus' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_batch_subjob_memory')):
                print("* 'aws_batch_subjob_memory' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'aws_batch_subjob_timeout')):
                print("* 'aws_batch_subjob_timeout' must be set if batchsystem is 'awsbatch'")
                error = 1
            if(empty_value(config, 'tempdir_default') or config['tempdir_default'] != "/dev/shm"):
                print("* RECOMMENDED that 'tempdir_default' be '/dev/shm' if awsbatch is used")
                error = 1
            if(empty_value(config, 'job_storage_mode') or config['job_storage_mode'] != "s3"):
                print("* 'job_storage_mode' must be set to 's3' batchsystem is 'awsbatch'")
                error = 1
        elif(config['batchsystem'] == "slurm"):
            if(empty_value(config, 'slurm_template')):
                print("* 'slurm_template' must be set if batchsystem is 'slurm'")
                error = 1
            if(empty_value(config, 'job_storage_mode') or config['job_storage_mode'] != "sharedfs"):
                print("* 'job_storage_mode' must be set to 'sharedfs' batchsystem is 'slurm'")
                error = 1
        else:
            print(f"* batchsystem '{config['batchsystem']}' is not supported. Only awsbatch and slurm are supported")


    return error



def main():

    config = parse_config("templates/all.ctrl")

    # Check some of the parameters we care about
    error = check_parameters(config)

    parser = argparse.ArgumentParser()
       
    parser.add_argument('--overwrite', action='store_true', 
        help="Deletes existing workflow and all associated data")

    args = parser.parse_args()

    workflow_dir = Path("/".join(["..", "workflow"]))
    workflow_dir.mkdir(parents=True, exist_ok=True)
    workflow_config = workflow_dir / "config.json"

    if workflow_config.is_file() and not args.overwrite:
        print(
'''
Workflow already has a config.json. If you are sure that you want to delete
the existing data, then re-run vflp_prepare_folders.py --overwrite
'''
        )
        exit(1)

    if(error and not args.skip_errors):
        print(
'''
Workflow has validation errors. If you are sure it is correct,
then re-run vfvs_prepare_folders.py --skip_errors (Not recommended!)
'''
        )
        exit(1)

    # Delete anything that is currently there...
    shutil.rmtree(workflow_dir)
    workflow_dir.mkdir(parents=True, exist_ok=True)

    # Update a few fields so they do not need to be computed later
    if(config['job_storage_mode'] == "sharedfs"):
        workunits_path = workflow_dir / "workunits"
        workunits_path.mkdir(parents=True, exist_ok=True)

        #
        config['sharedfs_workunit_path'] = workunits_path.resolve().as_posix()
        config['sharedfs_workflow_path'] = workflow_dir.resolve().as_posix()
        config['sharedfs_collection_path'] = Path(config['collection_folder']).resolve().as_posix()
     

    with open(workflow_config, "w") as json_out:
        json.dump(config, json_out, indent=4)


    collection_values = {}
    with open('templates/todo.all', "r") as read_file:
        for line in read_file:
            collection_key, ligand_count = line.strip().split(maxsplit=1)
            if(re.search(r'^\d+$', ligand_count)):
                collection_values[collection_key] = int(ligand_count)
            else:
                print(f"{collection_key} had non positive int count of '{ligand_count}'")
        with open('../workflow/todo.all', "w") as write_file:
            for collection_key in sorted(collection_values, key=collection_values.get, reverse=True):
                write_file.write(f"{collection_key} {collection_values[collection_key]}\n")



if __name__ == '__main__':
    main()
