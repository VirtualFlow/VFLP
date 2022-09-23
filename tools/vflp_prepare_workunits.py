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
# Description: Generate run files for AWS Batch
#
# Revision history:
# 2021-06-29  Original version
#
# ---------------------------------------------------------------------------



import tempfile
import tarfile
import os
import json
import re
import boto3
import logging
import sys
import pprint
import gzip
import shutil
from botocore.config import Config
from pathlib import Path


def parse_config(filename):
	
	with open(filename, "r") as read_file:
		config = json.load(read_file)

	return config


def publish_workunit(ctx, index, workunit_subjobs, status):
	
	# Create a temporary directory
	temp_dir = tempfile.TemporaryDirectory()

	# Generate the json.gz file with the configuration information

	workunit = {
		'config': ctx['config'],
		'subjobs': workunit_subjobs,
	}


	local_file_path = f"{temp_dir.name}/{index}.json.gz"
	with gzip.open(local_file_path, "wt") as json_gz:
		json.dump(workunit, json_gz, indent=4)

	if(ctx['config']['job_storage_mode'] == "s3"):
		# Upload it to S3....
		object_path = [
			ctx['config']['object_store_job_output_data_prefix_full'],
			"input",
			"tasks",
			f"{index}.json.gz"
		]
		object_name = "/".join(object_path)

		try:
			response = ctx['s3'].upload_file(local_file_path, ctx['config']['object_store_job_output_data_bucket'], object_name)
		except ClientError as e:
			logging.error(e)
			raise

		return {'subjobs': workunit_subjobs, 's3_download_path': object_name}

	elif(ctx['config']['job_storage_mode'] == "sharedfs"):
		sharedfs_workunit_path = Path(ctx['config']['sharedfs_workunit_path']) / f"{index}.json.gz"
		shutil.copyfile(local_file_path, sharedfs_workunit_path)
		temp_dir.cleanup()

		return {'subjobs': workunit_subjobs, 'download_path': sharedfs_workunit_path.as_posix()}



def gen_s3_download_path(ctx, metatranche, tranche, collection_name):

	object_path = [
		ctx['config']['object_store_ligand_library_prefix'],
		metatranche,
		tranche,
		f"{collection_name}.txt.gz"
	]
	object_name = "/".join(object_path)
	return object_name


def gen_sharedfs_path(ctx, metatranche, tranche, collection_name):

	sharedfs_path = [
		ctx['config']['sharedfs_collection_path'],
		metatranche,
		tranche,
		f"{collection_name}.txt.gz"
	]
	sharedfs_path_file = "/".join(sharedfs_path)
	return sharedfs_path_file




def add_collection_to_subjob(ctx, subjob, collection_key, collection_count, metatranche, tranche, collection_name):

	subjob['collections'][collection_key] = {
		'metatranche': metatranche,
		'tranche': tranche,
		'collection_name': collection_name,
		'ligand_count': collection_count,
		'fieldnames': ctx['config']['file_fieldnames']
	}

	if(ctx['config']['job_storage_mode'] == "s3"):
	 	download_s3_path = gen_s3_download_path(ctx, metatranche, tranche, collection_name)
	 	subjob['collections'][collection_key]['s3_bucket'] = ctx['config']['object_store_ligand_library_bucket']
	 	subjob['collections'][collection_key]['s3_download_path'] = gen_s3_download_path(ctx, metatranche, tranche, collection_name)

	elif(ctx['config']['job_storage_mode'] == "sharedfs"):
		subjob['collections'][collection_key]['sharedfs_path'] = gen_sharedfs_path(ctx, metatranche, tranche, collection_name)

	else:
		print(f"job_storage_mode must be either s3 or sharedfs (currently: {ctx['config']['job_storage_mode']})")
		exit(1)


def generate_subjob_init():

	subjob_init = {
		'collections': { 
	 	}
	 }

	return subjob_init

def process(ctx):

	config = ctx['config']
	
	status = {
		'overall' : {},
		'workunits' : {},
		'collections' : {
		}
	}

	workunits = status['workunits']

	current_workunit_index = 1
	current_workunit_subjobs = {}
	current_subjob_index = 0

	leftover_count = 0
	leftover_subjob = {
		'collections': {}
	}

	counter = 0

	total_lines = 0
	with open('../workflow/todo.all') as fp:
		for index, line in enumerate(fp):
			total_lines += 1

	print("Generating jobfiles....")
    # Max array size depends on if we are using Batch or Slurm

	if(config['batchsystem'] == "awsbatch"):
		max_array_job_size = int(config['aws_batch_array_job_size'])
	elif(config['batchsystem'] == "slurm"):
		max_array_job_size = int(config['slurm_array_job_size'])


	with open('../workflow/todo.all') as fp:
		for index, line in enumerate(fp):
			collection_key, collection_count = line.split()

			metatranche, tranche, collection_name = collection_key.split("_")
			

			collection_count = int(collection_count)

			# If it is large enough to be a subjob all on its own then do that
			if(collection_count >= int(config['ligands_todo_per_queue'])):

				current_workunit_subjobs[current_subjob_index] = generate_subjob_init()
				add_collection_to_subjob(
						ctx,
						current_workunit_subjobs[current_subjob_index],
						collection_key, collection_count, 
						metatranche, tranche, collection_name
						)

				current_subjob_index += 1
			
			# If not, dd it to the 'leftover pile'
			else:
				
				leftover_count += collection_count

				add_collection_to_subjob(
						ctx,
						leftover_subjob,
						collection_key, collection_count, 
						metatranche, tranche, collection_name
						)

				if(leftover_count >= int(config['ligands_todo_per_queue'])):
					current_workunit_subjobs[current_subjob_index] = leftover_subjob

					current_subjob_index += 1
					leftover_count = 0
					leftover_subjob = generate_subjob_init()
					

			if(len(current_workunit_subjobs) == max_array_job_size):
				workunits[current_workunit_index] = publish_workunit(ctx, current_workunit_index, current_workunit_subjobs, status)

				current_workunit_index += 1
				current_subjob_index = 0
				current_workunit_subjobs = {}

			counter += 1

			if(counter % 2000 == 0):
				percent = (counter / total_lines) * 100
				print(f" ({percent: .2f}%)")



	# If we have leftovers -- process them
	if(leftover_count > 0):
		current_workunit_subjobs[current_subjob_index] = leftover_subjob

	# If the current workunit has any items in it, we need to publish it
	if(len(current_workunit_subjobs) > 0):
		workunits[current_workunit_index] = publish_workunit(ctx,current_workunit_index, current_workunit_subjobs, status)
	else:
		# This is so we print the number of completed workunits at the end
		current_workunit_index -= 1
	
	print("Writing json")

	# Output all of the information about the workunits into JSON so we can easily grab this data in the future
	with open("../workflow/status.json", "w") as json_out:
		json.dump(status, json_out)

	os.system('cp ../workflow/status.json ../workflow/status.todolists.json') 

	print(f"Generated {current_workunit_index} workunits")


def main():

	ctx = {}
	ctx['config'] = parse_config("../workflow/config.json")
	aws_config = Config(
        region_name=ctx['config']['aws_region']
    )
	ctx['s3'] = boto3.client('s3', config=aws_config)


	process(ctx)


if __name__ == '__main__':
    main()



