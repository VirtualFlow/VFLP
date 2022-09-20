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
# Description: Get status of the AWS Batch jobs
#
# Revision history:
# 2021-06-29  Original version
#
# ---------------------------------------------------------------------------


import os
import json
import boto3
import botocore
import re
import tempfile
import gzip
import time
import logging
from botocore.config import Config
import argparse


batch_job_statuses = {
    'SUBMITTED': {
        'check_parent': 1,
        'check_subjobs': 0,
        'completed': 0,
        'order': 1
    },
    'PENDING': {
        'check_parent': 1,
        'check_subjobs': 1,
        'completed': 0,
        'order': 2
    },
    'RUNNABLE': {
        'check_parent': 1,
        'check_subjobs': 0,
        'completed': 0,
        'order': 3
    },
    'STARTING': {
        'check_parent': 1,
        'check_subjobs': 1,
        'completed': 0,
        'order': 4
    },
    'RUNNING': {
        'check_parent': 1,
        'check_subjobs': 1,
        'completed': 0,
        'order': 5
    },
    'SUCCEEDED': {
        'check_parent': 0,
        'check_subjobs': 1,
        'completed': 1,
        'order': 6
    },
    'FAILED': {
        'check_parent': 0,
        'check_subjobs': 1,
        'completed': 1,
        'order': 7
    },
}



def parse_config(filename):
    with open(filename, "r") as read_file:
        config = json.load(read_file)

    return config


def process(config):

    aws_config = Config(
        region_name=config['aws_region']
    )

    ctx = {}
    ctx['config'] = config
    ctx['temp_dir'] = tempfile.TemporaryDirectory()
    ctx['s3'] = boto3.client('s3', config=aws_config)
    client = boto3.client('batch', config=aws_config)

    # load the status file that is keeping track of the data
    with open("../workflow/status.json", "r") as read_file:
        status = json.load(read_file)

    workunits = status['workunits']


    
    parser = argparse.ArgumentParser()   
    parser.add_argument("workunit",
        help="Workunit ID to provide status on")
    parser.add_argument("--endworkunit",
        help="end Workunit ID to provide status on")

    args = parser.parse_args()

    status_count_success = {}
    status_count_failed = {}
    status_categories = {}

    counter = 0   
    # We also want to check on the status files themselves from each job/subjob
    # for workunit_key in workunits:

    workunit_key = args.workunit
    if(workunit_key not in workunits):
        print(f"{workunit_key} not found as a valid workunit")
        exit(1)


    if(args.endworkunit):
        workunits_to_run = range(int(workunit_key), int(args.endworkunit) + 1)
    else:
        workunits_to_run = [ workunit_key ]


    for workunit_key in workunits_to_run:
        workunit_key = str(workunit_key)

        if(workunit_key not in workunits):
            print(f"{workunit_key} not found as a valid workunit")
            continue

        workunit = workunits[workunit_key]

        counter += 1

        if(counter % 10 == 0):
            percent = (counter / len(workunits_to_run)) * 100
            print(f".... {percent: .2f}%")

        if 'status' not in workunit:
            print(f"{workunit_key} has no status yet - run vflp_get_status.py first")
            exit(1)

        for subjob_key in workunit['subjobs']:
            subjob = workunit['subjobs'][subjob_key]

            original_ligands_count = 0;
            final_ligand_count = 0;
            final_ligand_success_count = 0;

            if(subjob['status'] == "SUCCEEDED" or subjob['status'] == "FAILED"):
                if('processed' not in subjob or subjob['processed'] == 0):
                    for collection_key in subjob['collections']:
                        collection = subjob['collections'][collection_key]
                        collection_status = get_status_info(ctx, collection)

                        if(collection_status == None):
                            continue


                        for ligand_key in collection_status['ligands']:
                            original_ligands_count += 1

                            for tautomer_key in collection_status['ligands'][ligand_key]['tautomers']:
                                tautomer = collection_status['ligands'][ligand_key]['tautomers'][tautomer_key]
                                
                                final_ligand_count += 1 
                                if(tautomer['status'] == "success"):
                                    final_ligand_success_count += 1

                                # 
                                for status_desc in tautomer['status_sub']:
                                    status_category, status_entry = status_desc

                                    if not status_category in status_categories:
                                        status_categories[status_category] = 1
                                        status_count_success[status_category] = 0
                                        status_count_failed[status_category] = 0

                                    if(status_entry['state'] == "success"):
                                        status_count_success[status_category] += 1
                                    else:
                                        status_count_failed[status_category] += 1


                # output for the subjob?
                print(f"{workunit_key}:{subjob_key}: original: {original_ligands_count}, expanded: {final_ligand_count}, successful: {final_ligand_success_count}")
            else:
                print(f"{workunit_key}:{subjob_key} status is {subjob['status']}")

    for category in status_categories:
        print(f"{category}: {status_count_success[category]}, failed: {status_count_failed[category]}")



    #print("Writing the json status file out - Do not interrupt!")

    # Output all of the information about the workunits into JSON so we can easily grab this data in the future
    #with open("../workflow/status.json", "w") as json_out:
    #    json.dump(status, json_out)




def get_status_info_path(ctx, collection):
    remote_dir = [
        ctx['config']['object_store_job_ouput_data_prefix_full'],
        "complete",
        "status",
        collection['metatranche'],
        collection['tranche'],
    ]

    # Remote path
    remote_full_path = "/".join(remote_dir) + f"/{collection['collection_name']}.json.gz"
    return remote_full_path

def get_status_info(ctx, collection):


    remote_path = get_status_info_path(ctx, collection)
    job_bucket = ctx['config']['object_store_job_output_data_bucket']
    local_path = f"{ctx['temp_dir'].name}/tmp.json.gz"
    collection_status = None


    print(f"{job_bucket}:{remote_path}")

    try:
        with open(local_path, 'wb') as f:
            ctx['s3'].download_fileobj(job_bucket, remote_path, f)
    except botocore.exceptions.ClientError as error:
        logging.error(f"Failed to download from S3 {job_bucket}/{remote_path} to {local_path}, ({error})")
        #raise
    else:
        try:
            with gzip.open(local_path, 'rt') as f:
                collection_status = json.load(f)
        except Exception as err:
            logging.error(f"Cannot open {local_path}: {str(err)}")
            raise


    return collection_status


def main():
    logging.basicConfig(level=logging.ERROR)
    config = parse_config("../workflow/config.json")
    process(config)


if __name__ == '__main__':
    main()











