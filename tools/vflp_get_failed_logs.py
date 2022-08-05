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
# Description: Get CW Logs from failed jobs
#
# Revision history:
# 2021-09-14  Original version
#
# ---------------------------------------------------------------------------


import os
import json
import boto3
import botocore
import tempfile
from botocore.config import Config
from pathlib import Path


def parse_config(filename):
    
    with open(filename, "r") as read_file:
        config = json.load(read_file)

    return config


def process(config):

    aws_config = Config(
        region_name=config['aws_region']
    )

    client = boto3.client('logs', config=aws_config)

    # load the status file that is keeping track of the data
    with open("../workflow/status.json", "r") as read_file:
        status = json.load(read_file)

    workunits = status['workunits']


    for workunit_key in workunits:
        workunit = workunits[workunit_key]

        if 'status' not in workunit:
            print(f"{workunit_key} has no status yet - run vflp_get_status.py first")
            exit(1)

        for subjob_key in workunit['subjobs']:
            subjob = workunit['subjobs'][subjob_key]

            if('status' in subjob and subjob['status'] == "FAILED"):
            #if('status' in subjob and subjob['status'] == "SUCCEEDED"):
                output_dir = Path("../workflow") / "failed" / workunit_key / subjob_key
                output_dir.mkdir(parents=True, exist_ok=True)

                for attempt_index, attempt in enumerate(subjob['detailed_status']['attempts']):

                    output_file = output_dir / f"{attempt_index}.log"


                    if('exitCode' in attempt['container']):
                        exit_code = attempt['container']['exitCode']
                    else:
                        exit_code = "N/A"

                    if('statusReason' in attempt):
                        status_reason = attempt['statusReason']
                    else:
                        status_reason = "N/A"

                    if('logStreamName' in attempt['container']):
                        print(f"{workunit_key}:{subjob_key}: {output_file} ({exit_code}, {status_reason})")

                        log_stream_name = attempt['container']['logStreamName']
                    
                        with open(output_file, "w") as log_out:
                            for event in get_event_log(client, log_stream_name):
                                log_out.write(event['message'] + "\n")
                    else:
                        print(f"{workunit_key}:{subjob_key}: ({exit_code}, {status_reason})")




def get_event_log(client, log_stream_name):
    kwargs = {
        'logGroupName': '/aws/batch/job',
        'logStreamName': log_stream_name,
        'startFromHead': True
    }
    while True:
        r = client.get_log_events(**kwargs)
        yield from r['events']
        try:
            if('nextToken' in kwargs and r['nextForwardToken'] == kwargs['nextToken']):
                break
            kwargs['nextToken'] = r['nextForwardToken']

        except KeyError:
            print("got key failure")
            break




def main():

    config = parse_config("../workflow/config.json")
    process(config)


if __name__ == '__main__':
    main()