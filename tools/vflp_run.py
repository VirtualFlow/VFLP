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
# Description: Main runner for the individual workunits/subjobs
#              for ligand preparation
#
# Revision history:
# 2021-09-13  Initial version of VFLP ported to Python
#
# ---------------------------------------------------------------------------



import pathlib
import tempfile
import tarfile
import gzip
import os
import json
import re
import boto3
import multiprocessing
import subprocess
import botocore
import logging
import time
import pprint
import itertools
import csv
import socket
import atexit
import shutil
import hashlib
import rdkit
import rdkit.Chem.QED
import rdkit.Chem.Scaffolds.MurckoScaffold
import selfies
import numpy as np

from datetime import datetime
from pathlib import Path
from botocore.config import Config
from rdkit import Chem
from rdkit.Chem.MolStandardize import rdMolStandardize
from rdkit.Chem import MolToSmiles as mol2smi
from rdkit.Chem.EnumerateStereoisomers import EnumerateStereoisomers, StereoEnumerationOptions

####################
# Individual tasks that will be completed in parallel


def process_ligand(ctx):

	start_time = time.perf_counter()

	ctx['temp_dir'] = tempfile.TemporaryDirectory(prefix=ctx['temp_path'])
	ctx['intermediate_dir'] = get_intermediate_dir_ligand(ctx)

	completion_event = {
		'status': "failed",
		'base_ligand': ctx['ligand'],
		'ligands': {},
		'stereoisomers': {},
		'seconds': 0
	}

	base_ligand = completion_event['base_ligand']
	base_ligand['key'] = ctx['ligand_key']
	base_ligand['stereoisomers']: []
	base_ligand['timers'] = []
	base_ligand['status_sub'] = []
	base_ligand['remarks'] = {
		'collection_key': f"Original Collection: {ctx['collection_key']}"
	}

	print(f"* Processing {base_ligand['key']}")

	if(base_ligand['smi'] == ""):
		logging.error(f"    * Warning: Ligand {base_ligand['key']} skipped since SMI is blank")
		return completion_event;

	# De-salting
	step_timer_start = time.perf_counter()
	try:
		desalt(ctx, base_ligand)
	except RuntimeError as error:
		logging.warning("    * Warning: The desalting procedure has failed...")
		base_ligand['status_sub'].append(['desalt', { 'state': 'failed', 'text': 'desalting failed' } ])
		if(ctx['config']['desalting_obligatory'] == "true"):
			completion_event['seconds'] = time.perf_counter() - start_time
			return completion_event;
		else:
			logging.warning("    * Warning: Ligand will be further processed without desalting")

	base_ligand['timers'].append(['desalt', time.perf_counter() - step_timer_start])


	# Neutralization

	step_timer_start = time.perf_counter()
	try:
		neutralization(ctx, base_ligand)
	except RuntimeError as error:
		logging.error("    * Warning: The neutralization has failed.")
		base_ligand['status_sub'].append(['neutralization', { 'state': 'failed', 'text': f'Failed {str(error)}' } ])

		# Can we go on?
		if(ctx['config']['neutralization_obligatory'] == "true"):
			logging.error("    * Warning: Ligand will be skipped since a successful neutralization is required according to the controlfile.")
			completion_event['seconds'] = time.perf_counter() - start_time
			return completion_event

		logging.warning("    * Warning: Ligand will be further processed without neutralization")
		base_ligand['smi_neutralized'] = base_ligand['smi_desalted']

	base_ligand['timers'].append(['neutralization', time.perf_counter() - step_timer_start])


	# Stereoisomer generation

	step_timer_start = time.perf_counter()
	try:
		#base_ligand['smi_neutralized']
		stereoisomer_generation(ctx, base_ligand)
	except RuntimeError as error:
		logging.error(f"    * Warning: The stereoisomer generation has failed. (error: {str(error)}, smi: {str(base_ligand['smi_neutralized'])}")
		base_ligand['status_sub'].append(['stereoisomer', { 'state': 'failed', 'text': f'Failed {str(error)}' } ])

		# Can we go on?
		if(ctx['config']['stereoisomer_obligatory'] == "true"):
			logging.warning("    * Warning: Ligand will be skipped since a successful stereoisomer generation is required according to the controlfile.")
			completion_event['seconds'] = time.perf_counter() - start_time
			return completion_event
		else:
			base_ligand['stereoisomer_smiles'] = [ base_ligand['smi_neutralized'] ]

	base_ligand['timers'].append(['stereoisomer', time.perf_counter() - step_timer_start])

	# In some cases this will generate additional steroisomers, which we need to process -- in other cases it will just be
	# the same ligand
	number_of_stereoisomers = len(base_ligand['stereoisomer_smiles'])

	# Loop through every stereoisomer
	for index, stereoisomer_smile_full in enumerate(base_ligand['stereoisomer_smiles']):
		stereoisomer_timer_start = time.perf_counter()

		print(f"      * Processing Stereoisomer ({index+1} of {number_of_stereoisomers}) for {base_ligand['key']}")

		# If the SMILES string has a space, take the first part
		stereoisomer_smile = stereoisomer_smile_full.split()[0]
		stereoisomer_key = f"{base_ligand['key']}_S{index}"
		logging.debug(f"processing stereoisomer {index}, stereoisomer_key:{stereoisomer_key} smile:{stereoisomer_smile}")

		stereoisomer = {
			'key': stereoisomer_key,
			'smi': stereoisomer_smile,
			'remarks': base_ligand['remarks'].copy(),
			'status': "failed",
			'status_sub': [],
			'index': index,
			'seconds': 0,
			'timers': []
		}

		#
		completion_event['stereoisomers'][stereoisomer_key] = stereoisomer

		try:
			process_stereoisomer(ctx, base_ligand, stereoisomer, completion_event['ligands'])
		except RuntimeError as error:
			logging.error(f"Failed processing {stereoisomer_key} (error: {str(error)})")

		stereoisomer_timer_end = time.perf_counter()
		stereoisomer['seconds'] = stereoisomer_timer_end - stereoisomer_timer_start



	end_time = time.perf_counter()
	completion_event['seconds'] = end_time - start_time
	completion_event['status'] = "success"

	# captured and processed later
	return completion_event


def get_smi_string(ligand):
	return ligand['smi'].split()[0]


def process_stereoisomer(ctx, ligand, stereoisomer, completion_ligands):

	stereoisomer['status'] = "failed"

	# Tautomer generation
	step_timer_start = time.perf_counter()
	try:
		tautomer_generation(ctx, stereoisomer)
	except RuntimeError as error:
		logging.error(f"    * Warning: The tautomerization has failed. (error: {str(error)}, smi: {str(stereoisomer['smi'])}")
		stereoisomer['status_sub'].append(['tautomerization', { 'state': 'failed', 'text': f'Failed {str(error)}' } ])

		# Can we go on?
		if(ctx['config']['tautomerization_obligatory'] == "true"):
			logging.warning("    * Warning: stereoisomer will be skipped since a successful tautomerization is required according to the controlfile.")
			stereoisomer['timers'].append(['tautomerization', time.perf_counter() - step_timer_start])
			return
		else:
			stereoisomer['tautomer_smiles'] = [ stereoisomer['smi'] ]

	stereoisomer['timers'].append(['tautomerization', time.perf_counter() - step_timer_start])

	# In some cases this will generate additional tautomers, which we need to process -- in other cases it will just be
	# the same ligand
	number_of_tautomers = len(stereoisomer['tautomer_smiles'])


	# Loop through every tautomer
	for index, tautomer_smile_full in enumerate(stereoisomer['tautomer_smiles']):
		tautomer_timer_start = time.perf_counter()

		print(f"      ** Processing tautomer ({index+1} of {number_of_tautomers}) for {stereoisomer['key']}")

		# If the SMILES string has a space, take the first part
		tautomer_smile = tautomer_smile_full.split()[0]
		tautomer_key = f"{stereoisomer['key']}_T{index}"
		logging.debug(f"processing {index}, tautomer_key:{tautomer_key} smile:{tautomer_smile}")

		tautomer = {
			'key': tautomer_key,
			'smi': tautomer_smile,
			'smi_stereoisomer': stereoisomer['smi'],
			'smi_original': ligand['smi'],
			'remarks': ligand['remarks'].copy(),
			'status': "failed",
			'status_sub': [],
			'index': index,
			'seconds': 0,
			'timers': []
		}

		#
		completion_ligands[tautomer_key] = tautomer

		try:
			process_tautomer(ctx, ligand, completion_ligands[tautomer_key])
		except RuntimeError as error:
			logging.error(f"Failed processing {tautomer_key} (error: {str(error)})")

		tautomer_timer_end = time.perf_counter()
		tautomer['seconds'] = tautomer_timer_end - tautomer_timer_start

	stereoisomer['status'] = "success"


#######################
# Step 1: Desalt

def desalt(ctx, ligand):

	ligand['number_of_fragments'] = 1
	ligand['remarks']['desalting'] = ""
	if(ctx['config']['desalting'] == "true"):
		# Number of fragments in SMILES

		smi_string = get_smi_string(ligand)
		smi_string_parts = smi_string.split(".")

		if(len(smi_string_parts) == 1):
			# Not a salt
			ligand['status_sub'].append(['desalt', { 'state': 'success', 'text': 'untouched' } ])
			ligand['smi_desalted'] = smi_string
			ligand['remarks']['desalting'] = "The ligand was originally not a salt, therefore no desalting was carried out."

		elif(len(smi_string_parts) > 1):
			# need to desalt
			sorted_smi_string_parts = sorted(smi_string_parts, key=len)
			ligand['smallest_fragment'] = sorted_smi_string_parts[0]
			ligand['largest_fragment'] = sorted_smi_string_parts[1]
			ligand['number_of_fragments'] = len(smi_string_parts)
			ligand['status_sub'].append(['desalt', { 'state': 'success', 'text': 'genuine' } ])
			ligand['remarks']['desalting'] = "The ligand was desalted by extracting the largest organic fragment (out of {len(smi_string_parts)}) from the original structure."
			ligand['smi_desalted'] = ligand['largest_fragment']

		else:
			# this failed...
			raise RuntimeError(f"Failed to parse '{smi_string_parts}'")

	else:
		smi_string = get_smi_string(ligand)
		ligand['smi_desalted'] = smi_string


#######################
# Step 2: Neutralization

def run_neutralization_instance(ctx, ligand, program):
	step_timer_start = time.perf_counter()
	valid_programs = ("standardizer", "obabel")

	if(program == "none"):
		raise RuntimeError(f"No neutralization program remaining")
	elif(program not in valid_programs):
		raise RuntimeError(f"Neutralization program '{program}' is not valid")

	try:
		if(program == "standardizer"):
			run_chemaxon_neutralization_standardizer(ctx, ligand)
		elif(program == "obabel"):
			run_obabel_neutralization(ctx, ligand)
	except RuntimeError as error:
		ligand['timers'].append([f'{program}_neutralize', time.perf_counter() - step_timer_start])
		return error

	ligand['timers'].append([f'{program}_neutralize', time.perf_counter() - step_timer_start])


def run_neutralization_generation(ctx, ligand):
	try:
		run_neutralization_instance(ctx, ligand, ctx['config']['neutralization_program_1'])
	except RuntimeError as error:
		run_neutralization_instance(ctx, ligand, ctx['config']['neutralization_program_2'])

def neutralization(ctx, ligand):

	if(ctx['config']['neutralization'] == "true"):
		run = 0

		if(ctx['config']['neutralization_mode'] == "always"):
			run = 1;
		elif(ctx['config']['neutralization_mode'] == "only_genuine_desalting" and ligand['number_of_fragments'] > 1):
			run = 1
		elif(ctx['config']['neutralization_mode'] == "only_genuine_desalting_and_if_charged" and ligand['number_of_fragments'] > 1):
			match = re.search(r'(?P<charge>(\-\]|\+\]))', ligand['smi_desalted'])
			if(match):
				run = 1

		if(run):
			try:
				ret = run_neutralization_generation(ctx, ligand)
			except RuntimeError as error:
				raise

			ligand['status_sub'].append(['neutralization', { 'state': 'success', 'text': 'genuine' } ])
		else:
			# Skipping neutralization
			logging.debug("* This ligand does not need to be neutralized, leaving it untouched.")
			ligand['status_sub'].append(['neutralization', { 'state': 'success', 'text': 'untouched' } ])

			ligand['smi_neutralized'] = ligand['smi_desalted']

	else:
		# Skipping neutralization
		ligand['smi_neutralized'] = ligand['smi_desalted']


#######################
# Step 3: Stereoisomer Generation

def stereoisomer_generation_instance(ctx, ligand, program):
	step_timer_start = time.perf_counter()
	valid_programs = ("rdkit", "cxcalc")

	if(program == "none"):
		raise RuntimeError(f"No stereoisomer generation program remaining")
	elif(program not in valid_programs):
		raise RuntimeError(f"Stereoisomer generation program '{program}' is not valid")

	try:
		if(program == "cxcalc"):
			logging.info("Starting the stereoisomer generation with cxcalc")
			run_chemaxon_stereoisomer_generation(ctx, ligand)
			ligand['status_sub'].append(['stereoisomer', { 'state': 'success', 'text': '' } ])
		elif(program == "rdkit"):
			logging.info("Starting the stereoisomer generation with rdkit")
			# Need to include the option for only one (True option) or multiple stereoisomers (currently multiple)
			run_rdkit_stereoisomer_generation(ctx, ligand, False)
			ligand['status_sub'].append(['stereoisomer', { 'state': 'success', 'text': '' } ])
	except RuntimeError as error:
		ligand['timers'].append([f'{program}_stereoisomer_generation', time.perf_counter() - step_timer_start])
		return error

	ligand['timers'].append([f'{program}_stereoisomer_generation', time.perf_counter() - step_timer_start])

def stereoisomer_generation(ctx, ligand):

	if(ctx['config']['stereoisomer_generation'] == "true"):
		try:
			stereoisomer_generation_instance(ctx, ligand, ctx['config']['stereoisomer_generation_program_1'])
		except RuntimeError as error:
			stereoisomer_generation_instance(ctx, ligand, ctx['config']['stereoisomer_generation_program_2'])
	else:
		ligand['stereoisomer_smiles'] = [ ligand['smi_neutralized'] ]


#######################
# Step 3: Tautomerization

def tautomerization_instance(ctx, stereoisomer, program):
	step_timer_start = time.perf_counter()
	valid_programs = ("cxcalc", "obabel")

	if(program == "none"):
		raise RuntimeError(f"No tautomerization program remaining")
	elif(program not in valid_programs):
		raise RuntimeError(f"Tautomerization program '{program}' is not valid")

	try:
		if(program == "cxcalc"):
			logging.info("Starting the tautomerization with cxcalc")
			run_chemaxon_tautomer_generation(ctx, stereoisomer)
			stereoisomer['status_sub'].append(['tautomerization', {'state': 'success', 'text': ''}])
		elif(program == "obabel"):
			logging.info("Starting the tautomerization with obtautomer")
			run_obabel_tautomerization(ctx, stereoisomer)
			stereoisomer['status_sub'].append(['tautomerization', {'state': 'success', 'text': ''}])
	except RuntimeError as error:
		stereoisomer['timers'].append([f'{program}_tautomerize', time.perf_counter() - step_timer_start])
		return error

	stereoisomer['timers'].append([f'{program}_tautomerize', time.perf_counter() - step_timer_start])


def tautomer_generation(ctx, stereoisomer):

	if (ctx['config']['tautomerization'] == "true"):
		try:
			tautomerization_instance(ctx, stereoisomer, ctx['config']['tautomerization_program_1'])
		except RuntimeError as error:
			tautomerization_instance(ctx, stereoisomer, ctx['config']['tautomerization_program_2'])
	else:
		stereoisomer['tautomer_smiles'] = [stereoisomer['smi']]


#### For each Tautomer -- Steps 4-9

def process_tautomer(ctx, ligand, tautomer):

	tautomer['status'] = "failed"
	tautomer['smi_protomer'] = tautomer['smi']
	tautomer['intermediate_dir'] = get_intermediate_dir_tautomer(ctx, tautomer)

	if(ctx['config']['protonation_state_generation'] == "true"):
		try:
			run_protonation_generation(ctx, tautomer)
		except RuntimeError as error:
			tautomer['status_sub'].append(['protonation', { 'state': 'failed', 'text': f'{str(error)}' } ])

			logging.warning("* Warning: Both protonation attempts have failed.")

			if(ctx['config']['protonation_obligatory'] == "true"):
				logging.error("* Warning: Ligand will be skipped since a successful protonation is required according to the controlfile.")
				raise
			else:
				logging.error("* Warning: Ligand will be further processed without protonation, which might result in unphysiological protonation states.")
				tautomer['remarks']['protonation'] = "WARNING: Molecule was not protonated at physiological pH (protonation with both obabel and cxcalc has failed)"
		else:
			tautomer['status_sub'].append(['protonation', { 'state': 'success', 'text': '' } ])

	# Update remarks used in output files

	tautomer['remarks']['basic'] = "Small molecule (ligand)"
	tautomer['remarks']['compound'] = f"Compound: {tautomer['key']}"

	tautomer['remarks']['smiles_original'] = f"SMILES_orig: {tautomer['smi_original']}"
	tautomer['remarks']['smiles_current'] = f"SMILES_current: {tautomer['smi_protomer']}"

	# Generate data for the attributes as needed
	step_timer_start = time.perf_counter()
	tautomer['attr'] = generate_attributes(ctx, ligand, tautomer)
	tautomer['timers'].append(['attr-generation', time.perf_counter() - step_timer_start])

	# If there are specific attributes to place in remarks, do that now
	tautomer['remarks']['additional_attr'] = []
	for attribute_type in ctx['config']['attributes_to_generate']:
		tautomer['remarks']['additional_attr'].append(f"{attribute_type}: {tautomer['attr'][attribute_type]}")

	# Assign the tranches if needed
	step_timer_start = time.perf_counter()
	if(ctx['config']['tranche_assignments'] == "true"):
		try:
			tranche_assignment(ctx, ligand, tautomer)
		except RuntimeError as error:
			tautomer['status_sub'].append(['tranche-assignment', { 'state': 'failed', 'text': f'{str(error)}' } ])
			tautomer['timers'].append(['tranche-assignment', time.perf_counter() - step_timer_start])
			logging.error(f"tranche_assignment failed for {tautomer['key']}")
			logging.error("* Error: The tranche assignments have failed, ligand will be skipped.")
			raise RuntimeError('The tranche assignments have failed, ligand will be skipped') from error

	tautomer['status_sub'].append(['tranche-assignment', { 'state': 'success', 'text': '' } ])
	tautomer['timers'].append(['tranche-assignment', time.perf_counter() - step_timer_start])

	# If SELFIES are requested, generate them here since we will place them in the
	# pdb file as well

	if "selfies" in ctx['config']['target_formats'] :
		try:
			tautomer['status_sub'].append(['selfies', { 'state': 'success', 'text': '' } ])
			tautomer['selfies'] = selfies.encoder(tautomer['smi_protomer'])
			tautomer['remarks']['additional_attr'].append(f"selfies: {tautomer['selfies']}")
		except selfies.exceptions.EncoderError as error:
			tautomer['status_sub'].append(['selfies', { 'state': 'failed', 'text': f'{str(error)}' } ])
			raise RuntimeError('Selfies generation failed')


	# 3D conformation generation

	# Where to place any PDB output (either from conformation or generation step)
	tautomer['pdb_file'] = str(tautomer['intermediate_dir'] / f"gen.pdb")

	conformation_success = "true"
	if(ctx['config']['conformation_generation'] == "true"):
		step_timer_start = time.perf_counter()

		try:
			run_conformation_generation(ctx, tautomer, tautomer['pdb_file'])
		except RuntimeError as error:
			tautomer['status_sub'].append(['conformation', { 'state': 'failed', 'text': f'{str(error)}' } ])
			conformation_success = "false"
			logging.error(f"conformation_generation failed for {tautomer['key']}")
			if(ctx['config']['conformation_obligatory'] == "true"):
				tautomer['timers'].append(['conformation', time.perf_counter() - step_timer_start])
				raise RuntimeError(f'Conformation failed, but is required error:{str(error)}') from error
		else:
			tautomer['status_sub'].append(['conformation', { 'state': conformation_success, 'text': '' } ])

		tautomer['timers'].append(['conformation', time.perf_counter() - step_timer_start])

	## PDB Generation
	# If conformation generation failed, and we reached this point,
	# then conformation_obligatory=false, so we do not need to check this

	if(ctx['config']['conformation_generation'] == "false" or conformation_success == "false"):
		try:
			obabel_generate_pdb(ctx, tautomer, tautomer['pdb_file'])
		except RuntimeError as error:
			tautomer['status_sub'].append(['pdb-generation', { 'state': 'failed', 'text': f'{str(error)}' } ])
			logging.warning("    * Warning: Ligand will be skipped since a successful PDB generation is mandatory.")
			logging.error(f"obabel_generate_pdb failed for {tautomer['key']}")
			raise RuntimeError('PDB generation failed, but is required') from error

	# At this point a valid pdb file will be at tautomer['pdb_file']

	 # Checking the potential energy
	if(ctx['config']['energy_check'] == "true"):
		logging.warning("\n * Starting to check the potential energy of the ligand")

		if(not obabel_check_energy(ctx, tautomer, tautomer['pdb_file'], ctx['config']['energy_max'])):
			logging.warning("    * Warning: Ligand will be skipped since it did not pass the energy-check.")
			tautomer['status_sub'].append(['energy-check', { 'state': 'failed', 'text': '' } ])
			raise RuntimeError('Failed energy check')
		else:
			tautomer['status_sub'].append(['energy-check', { 'state': 'success', 'text': '' } ])

	## Target formats

	logging.debug(f"target formats is {ctx['config']['target_formats']}")
	step_timer_start = time.perf_counter()
	for target_format in ctx['config']['target_formats']:

		logging.debug(f"target_formats is {target_format}")

		# Put in the main job temporary directory, not the temp dir
		# for this ligand

		output_file_parts = [
			ctx['collection_temp_dir'].name,
			"complete",
			target_format,
			ctx['metatranche'],
			ctx['tranche'],
			ctx['collection_name']
		]

		output_dir = Path("/".join(output_file_parts))
		output_dir.mkdir(parents=True, exist_ok=True)

		if (ctx['config']['tranche_assignments'] == "true"):
			output_file = output_dir / f"{tautomer['tranche_string']}_{tautomer['key']}.{target_format}"
		else:
			output_file = output_dir / f"{tautomer['key']}.{target_format}"

		try:
			generate_target_format(ctx, tautomer, target_format, tautomer['pdb_file'], output_file)
		except RuntimeError as error:
			logging.error(f"failed generation for format {target_format}")
			tautomer['status_sub'].append(
				[f'targetformat-generation({target_format})', { 'state': 'failed', 'text': str(error) } ])
		else:
			logging.debug(f"succeeded generation for format {target_format}")
			tautomer['status_sub'].append(
				[f'targetformat-generation({target_format})', { 'state': 'success', 'text': '' } ])

	tautomer['timers'].append(['targetformats', time.perf_counter() - step_timer_start])

	# Mark the complete tautomer as successfully finished if we get here
	# Note that the target format generation could have failed at this point

	tautomer['status'] = "success"



def generate_target_format(ctx, tautomer, target_format, pdb_file, output_file):

	if(target_format == "smi"):
		# We can just use the SMI string that we already have
		write_file_single(output_file, tautomer['smi_protomer'])
	elif(target_format == "pdb"):
		# The input to this function is already a pdb file, so we can
		# just copy it
		shutil.copyfile(pdb_file, output_file)
	elif(target_format == "selfies"):
		# We can just use the SELFIES string that we already have
		write_file_single(output_file, tautomer['selfies'])
	else:
		obabel_generate_targetformat(ctx, tautomer, target_format, pdb_file, output_file)




#######################
# Step 4: Protonation


def run_protonation_instance(ctx, tautomer, program):
	step_timer_start = time.perf_counter()
	valid_programs = ("cxcalc", "obabel")

	if(program == "none"):
		raise RuntimeError(f"No protonation program remaining")
	elif(program not in valid_programs):
		raise RuntimeError(f"Protonation program '{program}' is not valid")

	try:
		if(program == "cxcalc"):
			cxcalc_protonate(ctx, tautomer)
		elif(program == "obabel"):
			run_obabel_protonation(ctx, tautomer)
	except RuntimeError as error:
		tautomer['timers'].append([f'{program}_protonate', time.perf_counter() - step_timer_start])
		return error

	tautomer['timers'].append([f'{program}_protonate', time.perf_counter() - step_timer_start])


def run_protonation_generation(ctx, tautomer):
	try:
		run_protonation_instance(ctx, tautomer, ctx['config']['protonation_program_1'])
	except RuntimeError as error:
		run_protonation_instance(ctx, tautomer, ctx['config']['protonation_program_2'])


#######################
# Step 5: Assign Tranche

def get_mol_attributes():
	return {
		"mw_obabel": { "prog": "obabel", "prog_name": "mol_weight", "val": "INVALID" },
		"logp_obabel": { "prog": "obabel", "prog_name": "logP", "val": "INVALID" },
		"tpsa_obabel": { "prog": "obabel", "prog_name": "PSA", "val": "INVALID" },
		"atomcount_obabel": { "prog": "obabel", "prog_name": "num_atoms", "val": "INVALID" },
		"bondcount_obabel": { "prog": "obabel", "prog_name": "num_bonds", "val": "INVALID" },
		"mr_obabel": { "prog": "obabel", "prog_name": "MR", "val": "INVALID" },
		"mw_jchem": { "prog": "cxcalc", "prog_name": "mass", "val": "INVALID" },
		"logp_jchem": { "prog": "cxcalc", "prog_name": "logp", "val": "INVALID" },
		"hbd_jchem": { "prog": "cxcalc", "prog_name": "donorcount", "val": "INVALID" },
		"hba_jchem": { "prog": "cxcalc", "prog_name": "acceptorcount", "val": "INVALID" },
		"rotb_jchem": { "prog": "cxcalc", "prog_name": "rotatablebondcount", "val": "INVALID" },
		"tpsa_jchem": { "prog": "cxcalc", "prog_name": "polarsurfacearea", "val": "INVALID" },
		"atomcount_jchem": { "prog": "cxcalc", "prog_name": "atomcount", "val": "INVALID" },
		"bondcount_jchem": { "prog": "cxcalc", "prog_name": "bondcount", "val": "INVALID" },
		"ringcount": { "prog": "cxcalc", "prog_name": "ringcount", "val": "INVALID" },
		"aromaticringcount": { "prog": "cxcalc", "prog_name": "aromaticringcount", "val": "INVALID" },
		"mr_jchem": { "prog": "cxcalc", "prog_name": "refractivity", "val": "INVALID" },
		"fsp3": { "prog": "cxcalc", "prog_name": "fsp3", "val": "INVALID" },
		"chiralcentercount": { "prog": "cxcalc", "prog_name": "chiralcentercount", "val": "INVALID" },
		"logd": { "prog": "cxcalc", "prog_name": "logd", "val": "INVALID" },
		"logs": { "prog": "cxcalc", "prog_name": "logs", "val": "INVALID" },
		"doublebondstereoisomercount_jchem": { "prog": "cxcalc", "prog_name": "doublebondstereoisomercount", "val": "INVALID" },
		"aromaticproportion_jchem": { "prog": "cxcalc", "prog_name": "aromaticproportion", "val": "INVALID" },
		"qed_rdkit": { "prog": "rdkit", "prog_name": "qed", "val": "INVALID" },
		"scaffold_rdkit": { "prog": "rdkit", "prog_name": "scaffold", "val": "INVALID" },
	}

def generate_attributes(ctx, ligand, tautomer):

	attribute_dict = {}
	attributes_to_generate = {}

	if(ctx['config']['tranche_assignments'] == "true"):
		for tranche_type in ctx['config']['tranche_types']:
			if tranche_type not in attributes_to_generate:
				attributes_to_generate[tranche_type] = 1
	for attribute_type in ctx['config']['attributes_to_generate']:
		if attribute_type not in attributes_to_generate:
			attributes_to_generate[attribute_type] = 1


	smi_file = f"{ctx['temp_dir'].name}/smi_tautomers_{tautomer['key']}.smi"
	write_file_single(smi_file, tautomer['smi_protomer'])

	attributes = get_mol_attributes()

	obabel_run = 0
	cxcalc_run = 0
	rdkit_run = 0

	for tranche_type in attributes_to_generate:
		if tranche_type in attributes:
			if(attributes[tranche_type]['prog'] == "obabel"):
				obabel_run = 1
			elif(attributes[tranche_type]['prog'] == "cxcalc"):
				cxcalc_run = 1
				nailgun_port = ctx['config']['nailgun_port']
				nailgun_host = ctx['config']['nailgun_host']
			elif(attributes[tranche_type]['prog'] == "rdkit"):
				rdkit_run = 1
		else:
			# We need to generate this one at a time
			attribute_dict[tranche_type] = generate_single_attribute(ctx, tranche_type, ligand, tautomer, smi_file)

	if(obabel_run == 1):
		run_obabel_attributes(ctx, tautomer, smi_file, attributes)

	if(cxcalc_run == 1):
		if('use_cxcalc_helper' in ctx['config']):
			use_single = int(ctx['config']['use_cxcalc_helper'])
		else:
			use_single = 0
		run_cxcalc_attributes(tautomer, smi_file, nailgun_port, nailgun_host, attributes_to_generate.keys(), attributes, use_single=use_single)

	if(rdkit_run == 1):
		run_rdkit_attributes(ctx, tautomer, tautomer['smi_protomer'], attributes_to_generate.keys(), attributes)


	# Put all of the attributes from obabel, cxcalc, and rdkit into
	# the return dict

	for tranche_type in attributes_to_generate:
		if tranche_type in attributes:
			attribute_dict[tranche_type] = attributes[tranche_type]['val']


	return attribute_dict;


def generate_single_attribute(ctx, attribute, ligand, tautomer, smi_file):

	if(attribute == "enamine_type"):
		return get_file_data(ligand, "enamine")
	elif(attribute == "hba_obabel"):
		return run_obabel_hba(smi_file, tautomer)
	elif(attribute == "hbd_obabel"):
		return run_obabel_hbd(smi_file, tautomer)
	elif(attribute == "formalcharge"):
		return formalcharge(tautomer['smi_protomer'])
	elif(attribute == "positivechargecount"):
		return positivecharge(tautomer['smi_protomer'])
	elif(attribute == "negativechargecount"):
		return negativecharge(tautomer['smi_protomer'])
	elif(attribute == "halogencount"):
		return halogencount(tautomer['smi_protomer'])
	elif(attribute == "sulfurcount"):
		return sulfurcount(tautomer['smi_protomer'])
	elif(attribute == "NOcount"):
		return NOcount(tautomer['smi_protomer'])
	elif(attribute == "electronegativeatomcount"):
		return electronegativeatomcount(tautomer['smi_protomer'])
	elif(attribute == "mw_file"):
		return get_file_data(ligand, "mw")
	elif(attribute == "logp_file"):
		return get_file_data(ligand, "logp")
	elif(attribute == "hba_file"):
		return get_file_data(ligand, "hba")
	elif(attribute == "hbd_file"):
		return get_file_data(ligand, "hbd")
	elif(attribute == "rotb_file"):
		return get_file_data(ligand, "rotb")
	elif(attribute == "tpsa_file"):
		return get_file_data(ligand, "tpsa")
	elif(attribute == "logd_file"):
		return get_file_data(ligand, "logd")
	elif(attribute == "logs_file"):
		return get_file_data(ligand, "logs")
	elif(attribute == "heavyatomcount_file"):
		return get_file_data(ligand, "heavyatomcount")
	elif(attribute == "ringcount_file"):
		return get_file_data(ligand, "ringcount")
	elif(attribute == "aromaticringcount_file"):
		return get_file_data(ligand, "aromaticringcount")
	elif(attribute == "mr_file"):
		return get_file_data(ligand, "mr")
	elif(attribute == "formalcharge_file"):
		return get_file_data(ligand, "formalcharge")
	elif(attribute == "positivechargecount_file"):
		return get_file_data(ligand, "positivecharge")
	elif(attribute == "negativechargecount_file"):
		return get_file_data(ligand, "negativechargeount")
	elif(attribute == "fsp3_file"):
		return get_file_data(ligand, "fsp3")
	elif(attribute == "chiralcentercount_file"):
		return get_file_data(ligand, "chiralcentercount")
	elif(attribute == "halogencount_file"):
		return get_file_data(ligand, "halogencount")
	elif(attribute == "sulfurcount_file"):
		return get_file_data(ligand, "sulfurcount")
	elif(attribute == "NOcount_file"):
		return get_file_data(ligand, "NOcount")
	elif(attribute == "electronegativeatomcount_file"):
		return get_file_data(ligand, "electronegativeatomcount")
	else:
		logging.error(f"The value '{attribute}'' of the variable used as an attribute is not supported.")
		raise RuntimeError(f"The value '{attribute}'' of the variable used as an attribute is not supported.")

def tranche_assignment(ctx, ligand, tautomer):

	tranche_value = ""
	tranche_string = ""

	tautomer['remarks']['trancheassignment_attr'] = []

	string_attributes = ['enamine_type']

	for tranche_type in ctx['config']['tranche_types']:

		if(tranche_type in tautomer['attr']):
			tranche_value = tautomer['attr'][tranche_type]
		else:
			logging.error(f"The value '{tranche_type}'' of the variable tranche_types is not supported.")
			raise RuntimeError(f"The value '{tranche_type}'' of the variable tranche_types is not supported.")

		tranche_value = str(tranche_value)

		if(tranche_type in string_attributes):
			# process as string
			letter = assign_character_mapping(ctx['config']['tranche_mappings'][tranche_type], tranche_value)
			logging.debug(f"Assigning {letter} based on '{tranche_value}' for type {tranche_type}. String now: {tranche_string}")
			tautomer['remarks']['trancheassignment_attr'].append(f"{tranche_type}: {tranche_value}")
		else:
			# Make sure we have a valid numerical value
			match = re.search(r'^([0-9+\-eE\.]+)$', tranche_value)
			if(match):
				letter = assign_character(ctx['config']['tranche_partitions'][tranche_type], tranche_value)

				logging.debug(f"Assigning {letter} based on '{tranche_value}' for type {tranche_type}. String now: {tranche_string}")
				tautomer['remarks']['trancheassignment_attr'].append(f"{tranche_type}: {tranche_value}")
			else:
				logging.error(f"Invalid result from tranche_type:{tranche_type}, value was: '{tranche_value}'")
				raise RuntimeError(f"Invalid result from tranche_type:{tranche_type}, value was: '{tranche_value}'")

		tranche_string += letter

	tautomer['tranche_string'] = tranche_string
	tautomer['remarks']['tranche_str'] = f"Tranche: {tranche_string}"

def assign_character_mapping(string_mapping, tranche_value):

	if(tranche_value in string_mapping):
		return string_mapping[tranche_value]

	return "X"


def assign_character(partitions, tranche_value):

	tranche_letters="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
	letter = ""

	logging.debug(f"Assigning letter for partitions {partitions}, tranche_value: {tranche_value}")

	# If less than the first one...
	if(float(tranche_value) <= float(partitions[0])):
		return tranche_letters[0]
	# If larger than the largest partition specified
	elif(float(tranche_value) > float(partitions[-1])):
		return tranche_letters[len(partitions)]

	# Otherwise go through each one until we are no longer smaller
	for index, partition_value in enumerate(partitions):
		if(float(tranche_value) > float(partition_value)):
			letter = tranche_letters[index + 1]
		else:
			break

	return letter

def halogencount(smi):
	return (
		smi.count('F')
		+ smi.count('Cl')
		+ smi.count('Br')
		+ smi.count('I')
	)

def electronegativeatomcount(smi):
	smi = smi.replace("Na", "")
	smi = smi.replace("Cl", "X")
	smi = smi.replace("Si", "")

	return len(re.findall("[NnOoSsPpFfXxBbIi]", smi))

def NOcount(smi):
	smi = smi.replace("Na", "")
	return (smi.count('N') + smi.count('O') +
		smi.count('n') + smi.count('o'))


def sulfurcount(smi):
	smi = smi.replace("Si", "")
	return smi.count('S')

def positivecharge(smi):
	smi = smi.replace("+2", "++")
	return smi.count('+')

def negativecharge(smi):
	smi = smi.replace("-2", "--")
	return smi.count('-')

def formalcharge(smi):
	return (positivecharge(smi) - negativecharge(smi))

def get_file_data(ligand, attribute):
	if attribute in ligand['file_data']:
		return ligand['file_data'][attribute]
	else:
		raise RuntimeError(f"Asked for attribute '{attribute}' that does not exist in file_data")


#######################
# Step 6: 3D conformation generation


def run_conformation_generation(ctx, tautomer, output_file):

	try:
		run_conformation_instance(ctx, tautomer, ctx['config']['conformation_program_1'], output_file)
	except RuntimeError as error:
		run_conformation_instance(ctx, tautomer, ctx['config']['conformation_program_2'], output_file)


def run_conformation_instance(ctx, tautomer, program, output_file):
	step_timer_start = time.perf_counter()
	valid_programs = ("molconvert", "obabel")

	if(program == "none"):
		raise RuntimeError(f"No conformation program remaining")
	elif(program not in valid_programs):
		raise RuntimeError(f"Conformation program '{program}' is not valid")

	try:
		if(program == "molconvert"):
			chemaxon_conformation(ctx, tautomer, output_file)
		elif(program == "obabel"):
			obabel_conformation(ctx, tautomer, output_file)
	except RuntimeError as error:
		tautomer['timers'].append([f'{program}_conformation', time.perf_counter() - step_timer_start])
		raise error

	tautomer['timers'].append([f'{program}_conformation', time.perf_counter() - step_timer_start])



# Sometimes the coordinates do not end up as 3D. In order to
# verify that they are not completely, flat take the coordinates and
# remove '0 . + -' from the lines and then see if there
# is anything left other than space. If we find at least one
# line with non-zero coordinates that is sufficient (VERIFY)

def nonzero_pdb_coordinates(output_file):

	with open(output_file, "r") as read_file:
		for line in read_file:
			line = line.strip()

			if(re.search(r"^(ATOM|HETATM)", line)):
				line_parts = line.split()

				components_to_check= "".join(line_parts[5:7])
				components_to_check = re.sub(r"[0.+-]", "", components_to_check)
				if(not re.search(r"^\s*$", line)):
					return True

	return False


def generate_remarks(remark_list, remark_order="default", target_format="pdb"):

	if(remark_order == "default"):
		remark_ordering = [
			'basic', 'compound', 'smiles_original', 'smiles_current',
			'desalting', 'neutralization', 'stereoisomer', 'tautomerization',
			'protonation', 'generation', 'conformation',
			'targetformat', 'trancheassignment', 'trancheassignment_attr',
			'additional_attr',
			'tranche_str', 'date', 'collection_key'
		]
	else:
		remark_ordering = remark_order


	if(target_format == "mol2"):
		remark_prefix = "# "
	elif(target_format =="pdb" or target_format == "pdbqt"):
		remark_prefix = "REMARK    "
	else:
		raise RuntimeError(f"Invalid target_format type ({target_format})for generating remarks")

	remark_parts = []
	for remark in remark_ordering:
		if(remark in remark_list):
			if(isinstance(remark_list[remark], list)):
				for sub_remark in remark_list[remark]:
					if(sub_remark != ""):
						remark_parts.append(remark_prefix + " * " + sub_remark)
			elif(remark_list[remark] != ""):
				remark_parts.append(remark_prefix + remark_list[remark])
	remark_string = "\n".join(remark_parts)

	return remark_string


#######################
# Step 7: PDB Generation
# [This only occurs if 3D conformation failed or Step 7 is not requested]
#
# Called directly from process_tautomer into obabel


#######################
# Step 8: Energy Check
#
# Called directly from process_tautomer into obabel


#######################
# Step 9: Generate Target Formats
#
# Called directly from process_tautomer into obabel


################
# Helper Functions
#


def debug_save_output(ctx, file, stdout="", stderr="", tautomer=None):
	if(ctx['store_all_intermediate_logs'] == "true"):
		if(tautomer != None):
			save_output(tautomer['intermediate_dir'] / file, stdout, stderr)
		else:
			save_output(ctx['intermediate_dir'] / file, stdout, stderr)


def save_output(save_logfile, save_stdout, save_stderr):
	with open(save_logfile, "w") as write_file:
		write_file.write("STDOUT ---------\n")
		write_file.write(save_stdout)
		write_file.write("\nSTDERR ---------\n")
		write_file.write(save_stderr)


def get_intermediate_dir_tautomer(ctx, tautomer):

	output_dir = get_intermediate_dir_ligand(ctx) / tautomer['key']
	output_dir.mkdir(parents=True, exist_ok=True)

	return output_dir


def get_intermediate_dir_ligand(ctx):

	base_temp_dir = ctx['temp_dir'].name

	if(ctx['store_all_intermediate_logs'] == "true"):
		base_temp_dir = ctx['collection_temp_dir'].name

	# Intermediate log storage
	output_file_parts = [
		base_temp_dir,
		"intermediate",
		ctx['metatranche'],
		ctx['tranche'],
		ctx['collection_name'],
		ctx['ligand_key']
	]

	output_dir = Path("/".join(output_file_parts))
	output_dir.mkdir(parents=True, exist_ok=True)

	return output_dir

def file_is_empty(filename):
	with open(filename, "r") as read_file:
		for line in read_file:
			return False
	return True


################
# ChemAxon Components


def run_chemaxon_general(chemaxon_args, nailgun_port, nailgun_host, must_have_output, timeout=30):

	chemaxon_args_x = []
	for arg in chemaxon_args:
		if(arg != ""):
			chemaxon_args_x.append(arg)

	cmd = [
		'ng', '--nailgun-server', nailgun_host, '--nailgun-port', nailgun_port,
		*chemaxon_args_x
	]

	try:
		ret = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
	except subprocess.TimeoutExpired as err:
		raise RuntimeError(f"chemaxon timed out") from err

	if ret.returncode != 0:
		logging.error(f"Chemaxon Return code is {ret.returncode}, stdout:{ret.stdout}, stderr:{ret.stderr}")
		raise RuntimeError(f"Chemaxon Return code is {ret.returncode}, stdout:{ret.stdout}, stderr:{ret.stderr}")
	else:
		output_lines = ret.stdout.splitlines()

		if(must_have_output and len(output_lines) == 0):
			raise RuntimeError("No output found for chemaxon and is required")
		else:
			for line in (ret.stdout.splitlines() + ret.stderr.splitlines()):
				if(re.search(r'refused', line)):
					raise RuntimeError("The Nailgun server seems to have terminated")
				elif(re.search(r'failed|timelimit|error|no such file|not found', line)):
					logging.error(f"cx: An error flag was detected in the log file ({line})")
					raise RuntimeError(f"An error flag was detected in the log file ({line})")

	return {
		'stdout': ret.stdout,
		'stderr': ret.stderr
	}


def run_chemaxon_calculator(cxargs, local_file, nailgun_port, nailgun_host, timeout=30):
	local_args = [
		"chemaxon.marvin.Calculator",
		*cxargs,
		local_file
	]

	return run_chemaxon_general(local_args, nailgun_port, nailgun_host, must_have_output=1, timeout=timeout)


# Step 1: Desalt (not performed by ChemAxon)
# Step 2: Neutralization by Standardizer

def run_chemaxon_neutralization_standardizer(ctx, ligand):

	step_timer_start = time.perf_counter()

	# Place smi string into a file that can be read
	local_file = ctx['intermediate_dir'] / "desalted.smi"
	write_file_single(local_file, ligand['smi_desalted'])

	local_args = [
		"chemaxon.standardizer.StandardizerCLI",
		local_file,
		"-c",
		"neutralize"
	]

	ret = run_chemaxon_general(local_args, ctx['config']['nailgun_port'], ctx['config']['nailgun_host'], must_have_output=1, timeout=ctx['config']['chemaxon_neutralization_timeout'])

	debug_save_output(stdout=ret['stdout'], stderr=ret['stderr'], ctx=ctx, file="chemaxon_neutralization")

	output_lines = ret['stdout'].splitlines()
	ligand['smi_neutralized'] = output_lines[-1]
	ligand['neutralization_success'] = 1
	ligand['remarks']['neutralization'] = f"The compound was neutralized by Standardizer version {ctx['versions']['standardizer']} of ChemAxons JChem Suite."
	ligand['neutralization_type'] ="genuine"

	ligand['timers'].append(['chemaxon_neutralization', time.perf_counter() - step_timer_start])


# Step 3a: Stereoisomer Generation by ChemAxon

def run_chemaxon_stereoisomer_generation(ctx, ligand):
	step_timer_start = time.perf_counter()

	# Place smi string into a file that can be read
	local_file = ctx['intermediate_dir'] / "neutralized.smi"
	write_file_single(local_file, ligand['smi_neutralized'])

	local_args = [
		"chemaxon.marvin.Calculator",
		"stereoisomers",
		*(ctx['config']['cxcalc_stereoisomer_generation_options'].split()),
		local_file,
	]


	ligand['stereoisomer_smiles'] = []

	ret = run_chemaxon_general(local_args, ctx['config']['nailgun_port'], ctx['config']['nailgun_host'], must_have_output=1, timeout=ctx['config']['cxcalc_stereoisomer_timeout'])


	debug_save_output(stdout=ret['stdout'], stderr=ret['stderr'], ctx=ctx, file="chemaxon_stereoisomer")

	lines = ret['stdout'].splitlines()
	if(len(lines) >= 1):
		for line in lines:
			ligand['stereoisomer_smiles'].append(line)

		ligand['remarks']['stereoisomer'] = f"The stereoisomers were generated by cxcalc version {ctx['versions']['cxcalc']} of ChemAxons JChem Suite."
		ligand['timers'].append(['chemaxon_stereoisomer', time.perf_counter() - step_timer_start])
		return
	else:
		raise RuntimeError("No output for stereoisomer state generation")

	raise RuntimeError("Stereoisomer generation failed")


# Step 3b: Tautomerization by ChemAxon

def run_chemaxon_tautomer_generation(ctx, stereoisomer):
	step_timer_start = time.perf_counter()

	# Place smi string into a file that can be read
	local_file = ctx['intermediate_dir'] / "stereoisomer.smi"
	write_file_single(local_file, stereoisomer['smi'])

	local_args = [
		"chemaxon.marvin.Calculator",
		"tautomers",
		*(ctx['config']['cxcalc_tautomerization_options'].split()),
		local_file
	]

	stereoisomer['tautomer_smiles'] = []

	ret = run_chemaxon_general(local_args, ctx['config']['nailgun_port'], ctx['config']['nailgun_host'], must_have_output=1, timeout=ctx['config']['cxcalc_tautomerization_timeout'])

	debug_save_output(stdout=ret['stdout'], stderr=ret['stderr'], ctx=ctx, file="chemaxon_tautomerization")

	lines = ret['stdout'].splitlines()

	if(len(lines) >= 1):
		tautomer_smiles_strings = lines[-1].split()
		if(len(tautomer_smiles_strings) > 1):
			stereoisomer['tautomer_smiles'] = tautomer_smiles_strings[1].split(".")
			stereoisomer['remarks']['tautomerization'] = f"The tautomeric state was generated by cxcalc version {ctx['versions']['cxcalc']} of ChemAxons JChem Suite."
			stereoisomer['timers'].append(['chemaxon_tautomerization', time.perf_counter() - step_timer_start])
			return
		else:
			stereoisomer['timers'].append(['chemaxon_tautomerization', time.perf_counter() - step_timer_start])
			raise RuntimeError(f"Not able to split last line on spaces line={'|'.join(lines)})")
	else:
		stereoisomer['timers'].append(['chemaxon_tautomerization', time.perf_counter() - step_timer_start])
		raise RuntimeError("No output for tautomer state generation")

	stereoisomer['timers'].append(['chemaxon_tautomerization', time.perf_counter() - step_timer_start])
	raise RuntimeError("Tautomer state generation failed")


# Step 4: Protonation by ChemAxon

def cxcalc_protonate(ctx, tautomer):


	logging.debug(f"Running protonation with cxcalc for {tautomer['key']}")

	# Place smi string into a file that can be read

	local_file = tautomer['intermediate_dir'] / f"before_protonate.smi"
	write_file_single(local_file, tautomer['smi'])

	ret = run_chemaxon_calculator([ 'majorms', "-H", str(ctx['config']['protonation_pH_value']) ], local_file, ctx['config']['nailgun_port'], ctx['config']['nailgun_host'], timeout=ctx['config']['cxcalc_protonation_timeout'])

	debug_save_output(stdout=ret['stdout'], stderr=ret['stderr'], ctx=ctx, tautomer=tautomer, file="chemaxon_protonate")

	logging.debug(f"succesful protonation with cxcalc for {tautomer['key']}")

	output_lines = ret['stdout'].splitlines()
	if(len(output_lines) > 1):
		line = output_lines[-1]
		line_split = line.split("\t", 2)
		if(len(line_split) > 1):
			tautomer['smi_protomer'] = line_split[1]

			# Chemaxon can sometimes provide a second string. Just use the
			# first one
			#parts = line_split[1].split()
			#if(len(parts) > 1):
			#	tautomer['smi_protomer'] = parts[0]
			#	print (f"smi_protomer just updated to {parts[0]}, was {line_split[1]}")

			tautomer['remarks']['protonation'] = f"Protonation state was generated at pH {ctx['config']['protonation_pH_value']} by cxcalc version {ctx['versions']['cxcalc']} of ChemAxons JChem Suite."
			logging.debug(f"smi_protomer is {tautomer['smi_protomer']}")
			return

	raise RuntimeError("Protonation state generation failed")


# Step 5: Assign Tranche

# Single function used to lookup multiple attributes for tranche
# assignment
#
# Get the last line of output, the value if interest is after the tab character


def run_cxcalc_attributes(tautomer, local_file, nailgun_port, nailgun_host, attribute_list, attributes, use_single=0):

	step_timer_start = time.perf_counter()

	if(use_single == 1):
		attrs = {}

		cxcalc_attrs = []
		for attr in attribute_list:
			if(attr in attributes and attributes[attr]['prog'] == "cxcalc"):
				cxcalc_attrs.append(attributes[attr]['prog_name'])

		local_args = [
			"vf.CxCalcAttr",
			local_file,
			*cxcalc_attrs
		]

		ret = run_chemaxon_general(local_args, nailgun_port, nailgun_host, must_have_output=1)

		# Check output
		output_lines = ret['stdout'].splitlines()
		if(len(output_lines) > 0):
			for line in output_lines:
				attr = line.split(",", 2)
				if(len(attr) == 2):
					(attr_key, attr_value) = line.split(",", 2)
					attrs[attr_key] = attr_value
				else:
					raise RuntimeError("Unable to parse output of CxCalcAttr")
		else:
			raise RuntimeError("Unable to parse output of CxCalcAttr")


		for attr in attribute_list:
			if(attr in attributes and attributes[attr]['prog'] == "cxcalc"):
				attributes[attr]['val'] = attrs[attributes[attr]['prog_name']]
	else:

		for attr in attribute_list:
			if(attr in attributes and attributes[attr]['prog'] == "cxcalc"):
				attributes[attr]['val'] = cxcalc_attribute(tautomer, local_file, [attributes[attr]['prog_name']], nailgun_port, nailgun_host)


	tautomer['timers'].append([f'chemaxon_attr', time.perf_counter() - step_timer_start])
	return attributes


def cxcalc_attribute(tautomer, local_file, arguments, nailgun_port, nailgun_host):

	step_timer_start = time.perf_counter()
	ret = run_chemaxon_calculator(arguments, local_file, nailgun_port, nailgun_host)

	output_lines = ret['stdout'].splitlines()
	if(len(output_lines) > 1):
		line = output_lines[-1]
		line_split = line.split("\t", 2)
		if(len(line_split) > 1):
			tautomer['timers'].append([f'chemaxon_attr_{arguments[0]}', time.perf_counter() - step_timer_start])
			return line_split[1]

	tautomer['timers'].append([f'chemaxon_attr_{arguments[0]}', time.perf_counter() - step_timer_start])
	raise RuntimeError("Unable to parse output of run_chemaxon_calculator")

#
# Step 6: 3D conformation generation


def chemaxon_conformation(ctx, tautomer, output_file):

	logging.debug(f"Running chemaxon_conformation on smi:'{tautomer['smi_protomer']}")

	output_file_tmp = f"{output_file}.tmp"
	input_file = f"{ctx['temp_dir'].name}/molconvert.conf.{tautomer['key']}_input.smi"

	write_file_single(input_file, tautomer['smi_protomer'])
	molconvert_generate_conformation(ctx, tautomer, input_file, output_file_tmp)

	if(not os.path.isfile(output_file_tmp)):
		logging.debug("No pdb file generated in conformation")
		raise RuntimeError("No pdbfile generated")
	if(file_is_empty(output_file_tmp)):
		logging.debug(f"chemaxon outputfile is empty. smi: |{tautomer['smi_protomer']}|")
		raise RuntimeError(f"chemaxon outputfile is empty. smi: |{tautomer['smi_protomer']}|")

	if(not nonzero_pdb_coordinates(output_file_tmp)):
		logging.debug(f"The output PDB file exists but does not contain valid coordinates.")
		raise RuntimeError("The output PDB file exists but does not contain valid coordinates.")

	# FIXME -- do we want this? This will grab only the first part of an SMI string and will
	# ignore extended attributes
	first_smile_component = tautomer['smi_protomer'].split()[0]

	tautomer['remarks']['conformation'] = f"Generation of the 3D conformation was carried out by molconvert version {ctx['versions']['molconvert']}"
	tautomer['remarks']['targetformat'] = "Format generated as part of 3D conformation"
	#tautomer['remarks']['smiles'] = f"SMILES: {first_smile_component}"


	# Modifying the header of the pdb file and correction of the charges in the pdb file in
	# order to be conform with the official specifications (otherwise problems with obabel)

	local_remarks = tautomer['remarks'].copy()
	local_remarks.pop('compound')
	remark_string = generate_remarks(local_remarks) + "\n"

	line_count = 0
	with open(output_file, "w") as write_file:
		write_file.write(f"COMPND    Compound: {tautomer['key']}\n")
		write_file.write(remark_string)
		with open(output_file_tmp, "r") as read_file:
			for line in read_file:
				line_count += 1
				if(re.search(r"TITLE|SOURCE|KEYWDS|EXPDTA|COMPND|HEADER|AUTHOR", line)):
					continue
				line = re.sub(r"REVDAT.*$", "\n", line)
				line = re.sub(r"NONE", "", line)
				line = re.sub(r" UN[LK] ", " LIG ", line)
				line = re.sub(r"\+0", "", line)
				line = re.sub(r"([+-])([0-9])$", r"\2\1", line)
				if(re.search(r"^\s*$", line)):
					continue
				write_file.write(line)

	logging.debug("success for chemaxon_conformation")

def molconvert_generate_conformation(ctx, tautomer, input_file, output_file):
	logging.debug(f"Running conformation with molconvert for {tautomer['key']}")
	run_molconvert([ *(str(ctx['config']['molconvert_3D_options']).split()) ], input_file, output_file, ctx['config']['nailgun_port'], ctx['config']['nailgun_host'], timeout=ctx['config']['molconvert_conformation_timeout'])


def run_molconvert(molconvert_3D_options, input_file, output_file, nailgun_port, nailgun_host, timeout=30):
	local_args = [
		"chemaxon.formats.MolConverter", "pdb:+H", *molconvert_3D_options,
		input_file, "-o", output_file
	]
	run_chemaxon_general(local_args, nailgun_port, nailgun_host, must_have_output=0, timeout=timeout)

# Step 7: Only occurs with OBabel (if ChemAxon fails / not available)
# Step 8: Energy Check (OBabel only)
# Step 9: Generate Target Formats (OBabel only)

################
# OBabel Components
#

# General functions for obabel and obtautomer

def run_obabel_general(obabelargs, timeout=30, save_logfile=""):

	obabelargs_x = []
	for arg in obabelargs:
		if(arg != ""):
			obabelargs_x.append(arg)

	cmd = [
		'obabel',
		*obabelargs
	]

	try:
		ret = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
	except subprocess.TimeoutExpired as err:
		raise RuntimeError(f"obabel timed out") from err

	if(ret.returncode != 0):
		raise RuntimeError(f"Return code from obabel is {ret.returncode}")

	for line in ret.stdout.splitlines() + ret.stderr.splitlines():
		if(re.search(r'failed|timelimit|error|no such file|not found', line)):
			raise RuntimeError(f"An error flag was detected in the log files from obabel")

	return {
		'stderr' : ret.stderr,
		'stdout' : ret.stdout
	}


def run_obtautomer_general(obtautomerargs, output_file, timeout=30, save_logfile=""):

	obtautomerargs_x = []
	for arg in obtautomerargs:
		if(arg != ""):
			obtautomerargs_x.append(arg)

	cmd = [
		'obtautomer',
		*obtautomerargs
	]

	try:
		ret = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
		write_file_single(output_file, ret.stdout)
	except subprocess.TimeoutExpired as err:
		raise RuntimeError(f"obtautomer timed out") from err

	if(ret.returncode != 0):
		raise RuntimeError(f"Return code from obtautomer is {ret.returncode}")

	for line in ret.stdout.splitlines() + ret.stderr.splitlines():
		if(re.search(r'failed|timelimit|error|no such file|not found', line)):
			raise RuntimeError(f"An error flag was detected in the log files from obtautomer")

	return {
		'stderr' : ret.stderr,
		'stdout' : ret.stdout
	}

def write_file_single(filename, data_to_write):
	with open(filename, "w") as write_file:
		write_file.write(data_to_write)
		write_file.write("\n")

def run_obabel_general_get_value(obabelargs, output_file, timeout=30):
	ret = run_obabel_general(obabelargs, timeout=timeout)

	if(not os.path.isfile(output_file)):
		raise RuntimeError(f"No output file from obabel")

	with open(output_file, "r") as read_file:
		lines = read_file.readlines()

	if(len(lines) == 0):
		raise RuntimeError(f"No output in file from obabel")

	return lines[0]

def run_obtautomer_general_get_value(obtautomerargs, output_file, timeout=30):
	ret = run_obtautomer_general(obtautomerargs, output_file, timeout=timeout)

	if(not os.path.isfile(output_file)):
		raise RuntimeError(f"No output file from obtautomer")

	with open(output_file, "r") as read_file:
		lines = read_file.readlines()

	if(len(lines) == 0):
		raise RuntimeError(f"No output in file from obtautomer")

	return lines

# Step 1: Desalt (not performed by OBabel)
# Step 2: Neutralization by OBabel

def run_obabel_neutralization(ctx, ligand):

	input_file = f"{ctx['temp_dir'].name}/obabel.neutra_input.smi"
	output_file = f"{ctx['temp_dir'].name}/obabel.neutra_output.smi"

	# Output the SMI to a temp input file
	write_file_single(input_file, ligand['smi_desalted'])

	cmd = [
		'-ismi', input_file,
		'--neutralize',
		'-osmi', '-O', output_file
	]

	ligand['smi_neutralized'] = run_obabel_general_get_value(cmd, output_file, timeout=ctx['config']['obabel_neutralization_timeout'])
	ligand['neutralization_success'] = 1
	ligand['remarks']['neutralization'] = "The compound was neutralized by Open Babel."
	ligand['neutralization_type'] = "genuine"

# Step 3a: Stereoisomer Generation by RDKit

def perform_isomer_unique_correction(ctx, sterio_smiles_ls):

	'''
    When RDkit enumerates sterio-isomers, some of them can be redundant.
    To resolve this, we use obabel to convert them into 3D, convert back to
    canonical smiles, and, use this as the final list of stereoisomer smiles
    for a particular molecule.

    Parameters
    ----------
    sterio_smiles_ls : list of strings
        A list of valid SMILES strings.

    Returns
    -------
    isomers_canon : list of strings
        A list of valid SMILES strings, containing the corrected smiles!.
    '''

	smi_file = ctx['intermediate_dir'] / "sterio.smi"
	sdf_file = ctx['intermediate_dir'] / "sterio.sdf"

	isomers_canon = []

	for smi in sterio_smiles_ls:
		with open(smi_file, 'w') as f:
			f.writelines(smi)

		subprocess.run([ 'obabel', smi_file, '--gen3D', '-O', sdf_file], capture_output=True, text=True, timeout=ctx['config']['obabel_stereoisomer_timeout'])
		subprocess.run(['rm', smi_file], capture_output=True, text=True, timeout=ctx['config']['obabel_stereoisomer_timeout'])
		subprocess.run(['obabel', sdf_file, '-O', smi_file], capture_output=True, text=True, timeout=ctx['config']['obabel_stereoisomer_timeout'])

		with open(smi_file, 'r') as f:
			new_smi = f.readlines()
		new_smi = new_smi[0].strip()

		subprocess.run(['rm', smi_file], capture_output=True, text=True, timeout=ctx['config']['obabel_stereoisomer_timeout'])
		subprocess.run(['rm', sdf_file], capture_output=True, text=True, timeout=ctx['config']['obabel_stereoisomer_timeout'])

		mol = Chem.MolFromSmiles(new_smi)
		new_smi_canon = Chem.MolToSmiles(mol, canonical=True)

		isomers_canon.append(new_smi_canon)

	return list(set(isomers_canon))


def run_rdkit_stereoisomer_generation(ctx, ligand, assigned=True):
	'''
    Enumerate all stereoisomers of the provided molecule SMILES string.
    Note: Only unspecified stereocenters are expanded.

    Parameters
    ----------
    smi : str
         Valid molecule SMILE string.
    assigned: bool
         if True, isomers will be generated for only the unasigned stereo-locations
                  for a smile (faster)
         if False, all isomer combinations will be generated, regardless of what is
                  specified in the input smile (slower)

    Returns
    -------
    stereo_smiles: list of strs.
         A list of valid smile strings, representing stereoisomers.

    '''

	step_timer_start = time.perf_counter()

	# Place smi string into a file that can be read
	local_file = ctx['intermediate_dir'] / "neutralized.smi"
	write_file_single(local_file, ligand['smi_neutralized'])

	m = Chem.MolFromSmiles(ligand['smi_neutralized'])
	if assigned == True:  # Faster
		opts = StereoEnumerationOptions(unique=True)
	else:
		opts = StereoEnumerationOptions(unique=True, onlyUnassigned=False)

	isomers = tuple(EnumerateStereoisomers(m, options=opts))

	ligand['stereoisomer_smiles'] = []
	for smi in sorted(Chem.MolToSmiles(x, isomericSmiles=True) for x in isomers):
		ligand['stereoisomer_smiles'].append(smi)

	if(ctx['config']['rdkit_stereoisomer_generation_unique_correction'] == "true"):
		ligand['stereoisomer_smiles'] = perform_isomer_unique_correction(ctx, ligand['stereoisomer_smiles'])

	if(len(ligand['stereoisomer_smiles']) >= 1):
		ligand['remarks']['stereoisomer'] = "The stereoisomers were generated by RDKit."
		ligand['timers'].append(['rdkit_stereoisomer', time.perf_counter() - step_timer_start])
		return
	else:
		raise RuntimeError("No output for stereoisomer state generation")

	raise RuntimeError("Stereoisomer generation failed")


# Step 3b: Tautomerization by OBabel

def run_obabel_tautomerization(ctx, stereoisomer):

	input_file = f"{ctx['temp_dir'].name}/obabel.tauto_input.smi"
	output_file = f"{ctx['temp_dir'].name}/obabel.tauto_output.smi"

	# Output the SMI to a temp input file
	write_file_single(input_file, stereoisomer['smi'])

	cmd = [
		input_file
	]

	stereoisomer['tautomer_smiles'] = []
	stereoisomer['tautomer_smiles'] = run_obtautomer_general_get_value(cmd, output_file, timeout=ctx['config']['obabel_tautomerization_timeout'])
	del (stereoisomer['tautomer_smiles'][-1])
	stereoisomer['tautomer_smiles'] = [i.strip() for i in stereoisomer['tautomer_smiles']]

	stereoisomer['remarks']['tautomerization'] = "The tautomeric state was generated by Open Babel."


# Step 4: Protonation

# Step 4: 3D Protonation


def run_obabel_protonation(ctx, tautomer):

	input_file = f"{ctx['temp_dir'].name}/obabel.proto.{tautomer['key']}_input.smi"
	output_file = f"{ctx['temp_dir'].name}/obabel.proto.{tautomer['key']}_output.smi"

	# Output the SMI to a temp input file
	write_file_single(input_file, tautomer['smi'])

	cmd = [
		'-p', ctx['config']['protonation_pH_value'],
		'-ismi', input_file,
		'-osmi' '-O', output_file
	]

	tautomer['smi_protomer'] = run_obabel_general_get_value(cmd, output_file, timeout=ctx['config']['obabel_protonation_timeout'])


# Step 5: Assign Tranche

def run_obabel_attributes(ctx, tautomer, local_file, attributes):

	step_timer_start = time.perf_counter()

	captured_attrs = {}
	obabel_attrs = []
	for attr in attributes:
		if(attributes[attr]['prog'] == "obabel"):
			obabel_attrs.append(attributes[attr]['prog_name'])


	cmd = [ 'obprop', local_file]
	try:
		ret = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
	except subprocess.TimeoutExpired as err:
		raise RuntimeError(f"obprop timed out") from err

	output_lines = ret.stdout.splitlines()

	if(len(output_lines) == 0):
		raise RuntimeError(f"No output file from oprop")
	else:
		for line in output_lines:
			line_values = line.split(maxsplit=1)

			if(len(line_values) == 2):
				line_key, line_value = line_values

				if(line_key in obabel_attrs):
					captured_attrs[line_key] = line_value
					logging.debug(f"Got {line_key}:{line_value} for obabel")


	for attr in attributes:
		if(attributes[attr]['prog'] == "obabel"):
			if attributes[attr]['prog_name'] in captured_attrs:
				attributes[attr]['val'] = captured_attrs[attributes[attr]['prog_name']]

	tautomer['timers'].append(['obabel_attributes', time.perf_counter() - step_timer_start])




def run_obabel_hbX(local_file, append_val):

	return_val = "INVALID"
	cmd = ['-ismi', local_file, '-osmi', '--append', append_val]

	ret = run_obabel_general(cmd)
	output_lines = ret['stdout'].splitlines()

	if(len(output_lines) == 0):
		raise RuntimeError(f"No output file from obabel")
	else:
		line_values = output_lines[0].split()
		if(len(line_values) >= 2):
			# line_key, line_value = line_values
			# return the last value -- sometimes there are two strings
			return line_values[-1]

	raise RuntimeError(f"Unable to parse attribute from obabel")

def run_obabel_hba(local_file, tautomer):
	step_timer_start = time.perf_counter()
	attr_val = run_obabel_hbX(local_file, 'HBA1')
	tautomer['timers'].append(['obabel_attr_hba', time.perf_counter() - step_timer_start])
	return attr_val

def run_obabel_hbd(local_file, tautomer):
	step_timer_start = time.perf_counter()
	attr_val = run_obabel_hbX(local_file, 'HBD')
	tautomer['timers'].append(['obabel_attr_hbd', time.perf_counter() - step_timer_start])
	return attr_val

#
# Step 6: 3D conformation generation
def obabel_generate_pdb_general(ctx, tautomer, output_file, conformation, must_have_output=1, timeout=30):


	input_file = f"{ctx['temp_dir'].name}/obabel.conf.{tautomer['key']}_input.smi"
	write_file_single(input_file, tautomer['smi_protomer'])

	output_file_tmp = f"{output_file}.tmp"
	if(conformation):
		cmd = [ '--gen3d', '-ismi', input_file, '-opdb', '-O', output_file_tmp]
		logging.debug(f"Running obabel conformation on smi:'{tautomer['smi_protomer']}")
	else:
		cmd = ['-ismi', input_file, '-opdb', '-O', output_file_tmp]


	ret = run_obabel_general(cmd, timeout=timeout)
	output_lines = ret['stdout'].splitlines()

	if(must_have_output and len(output_lines) == 0):
		raise RuntimeError(f"No output")

	if(not os.path.isfile(output_file_tmp)):
		raise RuntimeError(f"No PDB file generated")
	if(file_is_empty(output_file_tmp)):
		raise RuntimeError(f"obabel outputfile is empty (smi: {tautomer['smi_protomer']}")
	if(not nonzero_pdb_coordinates(output_file_tmp)):
		raise RuntimeError(f"The output PDB file exists but does not contain valid coordinates.")

	# We are successful
	if(conformation):
		tautomer['remarks']['conformation'] = f"Generation of the 3D conformation was carried out by Open Babel version {ctx['versions']['obabel']}"
		tautomer['remarks']['targetformat'] = "Format generated as part of conformation."
	else:
		tautomer['remarks']['generation'] = f"Generation of the the PDB file (without conformation generation) was carried out by Open Babel version {ctx['versions']['obabel']}"
		tautomer['remarks']['targetformat'] = "Format generated as part of generation."

	first_smile_component = tautomer['smi_protomer'].split()[0]
	#tautomer['remarks']['smiles'] = f"SMILES: {first_smile_component}"

	local_remarks = tautomer['remarks'].copy()
	local_remarks.pop('compound')
	remark_string = generate_remarks(local_remarks) + "\n"

	# Modify the output file as needed #
	with open(output_file, "w") as write_file:
		write_file.write(f"COMPND    Compound: {tautomer['key']}\n")
		write_file.write(remark_string)

		with open(output_file_tmp, "r") as read_file:

			for line in read_file:
				if(re.search(r"COMPND|AUTHOR", line)):
					continue

				if(re.search(r"^\s*$", line)):
					continue

				line = re.sub(r" UN[LK] ", " LIG ", line)
				write_file.write(line)



def obabel_conformation(ctx, tautomer, output_file):
	obabel_generate_pdb_general(ctx, tautomer, output_file, conformation=1, must_have_output=0, timeout=ctx['config']['obabel_conformation_timeout'])

# Step 7: PDB Generation

def obabel_generate_pdb(ctx, tautomer, output_file):
	step_timer_start = time.perf_counter()
	obabel_generate_pdb_general(ctx, tautomer, output_file, conformation=0, must_have_output=0)
	tautomer['timers'].append(['obabel_generation', time.perf_counter() - step_timer_start])

# Step 8: Energy Check
# Format for last line should be:
# 	obv2:	TOTAL ENERGY = 91.30741 kcal/mol
# 	obv3:	TOTAL ENERGY = 880.18131 kJ/mol
# VERIFY

def obabel_check_energy(ctx, tautomer, input_file, max_energy):

	step_timer_start = time.perf_counter()

	with open(input_file, "r") as read_file:
		lines = read_file.readlines()

	try:
		ret = subprocess.run([ 'obenergy', input_file], capture_output=True, text=True, timeout=30)
	except subprocess.TimeoutExpired as err:
		tautomer['timers'].append(['obenergy', time.perf_counter() - step_timer_start])
		raise RuntimeError(f"obprop timed out") from err

	tautomer['timers'].append(['obenergy', time.perf_counter() - step_timer_start])

	debug_save_output(stdout=ret.stdout, stderr=ret.stderr, tautomer=tautomer, ctx=ctx, file="energy_check")

	output_lines = ret.stdout.splitlines()

	kcal_to_kJ = 4.184

	if(len(output_lines) > 0):
		# obabel v2
		match = re.search(r"^TOTAL\s+ENERGY\s+\=\s+(?P<energy>\d+\.?\d*)\s+(?P<energy_unit>(kcal|kJ))", output_lines[-1])
		if(match):
			energy_value = float(match.group('energy'))
			if(match.group('energy_unit') == "kcal"):
				energy_value *= kcal_to_kJ

			if(energy_value <= float(max_energy)):
				return 1

	tautomer['status_sub'].append(['energy-check', { 'state': 'failed', 'text': "|".join(output_lines) } ])

	return 0

# Step 9: Generate Target Formats

def obabel_generate_targetformat(ctx, tautomer, target_format, input_pdb_file, output_file):

	step_timer_start = time.perf_counter()

	output_file_tmp = tautomer['intermediate_dir'] / f"tmp.{target_format}"

	cmd = [
		'-ipdb', input_pdb_file,
		'-O', output_file_tmp
	]

	ret = run_obabel_general(cmd)

	if(not os.path.isfile(output_file_tmp)):
		logging.debug("no output file generated")
		tautomer['timers'].append([f'obabel_generate_{target_format}', time.perf_counter() - step_timer_start])
		raise RuntimeError("No output file generated")

	if(target_format == "pdb" or target_format == "pdbqt"):
		if(not nonzero_pdb_coordinates(output_file_tmp)):
			logging.debug("The output PDB(QT) file exists but does not contain valid coordinates")
			tautomer['timers'].append([f'obabel_generate_{target_format}', time.perf_counter() - step_timer_start])
			raise RuntimeError("The output PDB(QT) file exists but does not contain valid coordinates.")

	# Slurp in the temporary file

	lines = ()
	with open(output_file_tmp, "r") as read_file:
		lines = read_file.readlines()

	if(len(lines) == 0):
		logging.debug("Output file is empty")
		tautomer['timers'].append([f'obabel_generate_{target_format}', time.perf_counter() - step_timer_start])
		raise RuntimeError("The output file is empty.")

	# Setup the remarks information
	now = datetime.now()


	remark_string = ""
	if(target_format == "pdb"):
		remarks = tautomer['remarks'].copy()
		remarks.pop('compound')
		remarks['targetformat'] = f"Generation of the the target format file ({target_format}) was carried out by Open Babel version {ctx['versions']['obabel']}"
		remarks['date'] = f'Created on {now.strftime("%Y-%m-%d %H:%M:%S")}'
		remark_string += f"COMPND    Compound: {tautomer['key']}\n"
		remark_string += generate_remarks(remarks, remark_order=['targetformat', 'date'] ,target_format=target_format) + "\n"
	elif(target_format == "pdbqt"):
		remarks = tautomer['remarks'].copy()
		remarks.pop('compound')
		remarks['targetformat'] = f"Generation of the the target format file ({target_format}) was carried out by Open Babel version {ctx['versions']['obabel']}"
		remarks['date'] = f'Created on {now.strftime("%Y-%m-%d %H:%M:%S")}'
		remark_string += f"REMARK    Compound: {tautomer['key']}\n"
		remark_string += generate_remarks(remarks, target_format=target_format) + "\n"
	elif(target_format == "mol2"):
		remarks = tautomer['remarks'].copy()
		remarks['targetformat'] = f"Generation of the the target format file ({target_format}) was carried out by Open Babel version {ctx['versions']['obabel']}"
		remarks['date'] = f'Created on {now.strftime("%Y-%m-%d %H:%M:%S")}'
		remark_string = generate_remarks(remarks, target_format=target_format) + "\n"


	# Output the final file

	if(target_format == "smi"):
		# get rid of the source file comment that Open Babel adds
		smi_string = lines[0].split()[0]
		with open(output_file, "w") as write_file:
			write_file.write(f"{smi_string}\n")

	else:
		with open(output_file, "w") as write_file:
			if(remark_string != ""):
				write_file.write(remark_string)

			for line in lines:
				if(target_format == "pdb" or target_format == "pdbqt"):
					if(re.search(r"TITLE|SOURCE|KEYWDS|EXPDTA|REVDAT|HEADER|AUTHOR", line)):
						continue
					line = re.sub(r" UN[LK] ", " LIG ", line)
					if(re.search(r"^\s*$", line)):
						continue
					if(re.search(r'REMARK\s+Name', line)):
						continue

				# OpenBabel often has local path information that we can remove
				line = re.sub(rf"{input_pdb_file}", tautomer['key'], line)

				write_file.write(line)

	logging.debug(f"Finished the target format of {target_format}")
	tautomer['timers'].append([f'obabel_generate_{target_format}', time.perf_counter() - step_timer_start])



################
# RDKit
#

def run_rdkit_attributes(ctx, tautomer, smi, attributes_to_gen, attributes):

	step_timer_start = time.perf_counter()

	mol = rdkit.Chem.MolFromSmiles(smi)

	for attr in attributes_to_gen:
		if(attr in attributes and attributes[attr]['prog'] == "rdkit"):
			if(attr == "qed_rdkit"):
				attributes[attr]['val'] = rdkit.Chem.QED.qed(mol)
			elif(attr == "scaffold_rdkit"):
				attributes[attr]['val'] = rdkit.Chem.MolToSmiles(rdkit.Chem.Scaffolds.MurckoScaffold.GetScaffoldForMol(mol),canonical=True)

	tautomer['timers'].append(['rdkit_attributes', time.perf_counter() - step_timer_start])


################
# General Components
#

def generate_tarfile(dir):
	os.chdir(str(Path(dir).parents[0]))

	with tarfile.open(f"{os.path.basename(dir)}.tar.gz", "x:gz") as tar:
		tar.add(os.path.basename(dir))

	return os.path.join(str(Path(dir).parents[0]), f"{os.path.basename(dir)}.tar.gz")



def get_collection_hash(collection_key):
	string_to_hash = f"{collection_key}"
	return hashlib.sha256(string_to_hash.encode()).hexdigest()


####### Main thread

# We now expect our config file to be a JSON file

def parse_config(filename):

	with open(filename, "r") as read_file:
		config = json.load(read_file)

	return config


def is_cxcalc_used(ctx):
	used = False

	if (ctx['main_config']['tautomerization'] == "true" and
			(ctx['main_config']['tautomerization_program_1'] == "cxcalc" or
			 ctx['main_config']['tautomerization_program_2'] == "cxcalc")):
		used = True

	if (ctx['main_config']['protonation_state_generation'] == "true" and
			(ctx['main_config']['protonation_program_1'] == "cxcalc" or
			 ctx['main_config']['protonation_program_2'] == "cxcalc")):
		used = True

	# In addition to these, there are some tranche assignment functions that use
	# cxcalc. Original code does not cover these, but should be addressed

	return used

def is_molconvert_used(ctx):
	used = False
	if (ctx['main_config']['conformation_generation'] == "true" and
			(ctx['main_config']['conformation_program_1'] == "molconvert" or
			 ctx['main_config']['conformation_program_2'] == "molconvert")):
		used = True

	return used

def is_standardizer_used(ctx):
	used = False
	if (ctx['main_config']['neutralization'] == "true" and
			(ctx['main_config']['neutralization_program_1'] == "standardizer" or
			 ctx['main_config']['neutralization_program_2'] == "standardizer")):
		used = True

	return used


def is_nailgun_needed(ctx):
	return is_cxcalc_used(ctx) or is_molconvert_used(ctx) or  is_standardizer_used(ctx)


def is_rdkit_needed(ctx):

	attributes = get_mol_attributes()
	if(ctx['main_config']['tranche_assignments'] == "true"):
		for tranche_type in ctx['main_config']['tranche_types']:
			if tranche_type in attributes:
				if(attributes[tranche_type]['prog'] == "rdkit"):
					return True

	elif(ctx['main_config']['stereoisomer_generation'] == "true" and
			(ctx['main_config']['stereoisomer_generation_program_1'] == "rdkit" or
			 ctx['main_config']['stereoisomer_generation_program_2'] == "rdkit")):
		return True

	return False


def get_helper_versions(ctx):

	ctx['versions'] = {
		'cxcalc': "INVALID",
		'molconvert': "INVALID",
		'standardizer': "INVALID",
		'obabel': "INVALID"
	}

	if (is_cxcalc_used(ctx)):
		ret = subprocess.run(f"ng --nailgun-server {ctx['main_config']['nailgun_host']} --nailgun-port {ctx['main_config']['nailgun_port']} chemaxon.marvin.Calculator | grep -m 1 version | sed 's/.*version \([0-9. ]*\).*/\\1/'", capture_output=True, text=True, shell=True, timeout=15)
		if(ret.returncode != 0):
			logging.error("Cannot connect to nailgun server for cxcalc version")
			raise RuntimeError("Cannot connect to nailgun server for cxcalc version")
		ctx['versions']['cxcalc'] = ret.stdout.strip()
		logging.error(f"{ctx['main_config']['nailgun_port']}:{ctx['main_config']['nailgun_host']}: cxcalc version is {ctx['versions']['cxcalc']}")

		ret = subprocess.run(f"ng --nailgun-server {ctx['main_config']['nailgun_host']} --nailgun-port {ctx['main_config']['nailgun_port']} chemaxon.marvin.Calculator", capture_output=True, text=True, shell=True, timeout=15)
		logging.error(f"CXCALC version: {ret.returncode}, {ret.stderr}, {ret.stdout}")


	if (is_molconvert_used(ctx)):
		ret = subprocess.run(f"ng --nailgun-server {ctx['main_config']['nailgun_host']} --nailgun-port {ctx['main_config']['nailgun_port']} chemaxon.formats.MolConverter | grep -m 1 version | sed 's/.*version \([0-9. ]*\).*/\\1/'", capture_output=True, text=True, shell=True, timeout=15)
		if(ret.returncode != 0):
			raise RuntimeError("Cannot connect to nailgun for molconvert version")
		ctx['versions']['molconvert'] = ret.stdout.strip()

	if(is_standardizer_used(ctx)):
		ret = subprocess.run(f"ng --nailgun-server {ctx['main_config']['nailgun_host']} --nailgun-port {ctx['main_config']['nailgun_port']} chemaxon.standardizer.StandardizerCLI -h | head -n 1 | awk -F '[ ,]' '{{print $2}}'", capture_output=True, text=True, shell=True, timeout=15)
		if(ret.returncode != 0):
			raise RuntimeError("Cannot connect to nailgun for standardizer version")
		ctx['versions']['standardizer'] = ret.stdout.strip()

	# OpenBabel is required across all configurations
	ret = subprocess.run(f"obabel -V | awk '{{print $3}}'", capture_output=True, text=True, shell=True, timeout=15)
	if(ret.returncode != 0):
		raise RuntimeError("Cannot get obabel version")
	ctx['versions']['obabel'] = ret.stdout.strip()

# This has the potential for a race condition. Better
# solution is if Nailgun could report port that it is using

def get_free_port():
	sock = socket.socket()
	sock.bind(('', 0))
	return sock.getsockname()[1]

def start_ng_server(host, port_num, java_max_heap_size):
	logging.error(f"starting on {host}:{port_num}")
	cmds = ['java', f'-Xmx{java_max_heap_size}G', 'com.martiansoftware.nailgun.NGServer', f'{host}:{port_num}']
	ng_process =  subprocess.Popen(cmds, start_new_session=True)

	# Nailgun can take a while to come up
	#
	time.sleep(10)

	return ng_process


def cleanup_ng(ng_process):
	# Stop the Nailgun serve
	ng_process.kill()
	print("Nailgun stopped")


def get_workunit_information():

	workunit_id = os.getenv('VFLP_WORKUNIT','')
	subjob_id = os.getenv('VFLP_WORKUNIT_SUBJOB','')

	if(workunit_id == "" or subjob_id == ""):
		raise RuntimeError(f"Invalid VFLP_WORKUNIT and/or VFLP_WORKUNIT_SUBJOB")

	return workunit_id, subjob_id


def get_subjob_config(ctx, workunit_id, subjob_id):


	ctx['job_storage_mode'] = os.getenv('VFLP_JOB_STORAGE_MODE', 'INVALID')

	if(ctx['job_storage_mode'] == "s3"):
		# Get the initial bootstrap information
		job_object = os.getenv('VFLP_CONFIG_JOB_OBJECT')
		job_bucket = os.getenv('VFLP_CONFIG_JOB_BUCKET')
		download_to_workunit_file = f"{ctx['temp_dir'].name}/{workunit_id}.json.gz"

		# Download workunit from S3
		get_workunit_from_s3(ctx, workunit_id, subjob_id, job_bucket, job_object, download_to_workunit_file)

		# Get the subjob config and main config information (same file)
		try:
			with gzip.open(download_to_workunit_file, 'rt') as f:
				subjob_config = json.load(f)
				ctx['main_config'] = subjob_config['config']

				if(subjob_id in subjob_config['subjobs']):
					ctx['subjob_config'] = subjob_config['subjobs'][subjob_id]
				else:
					logging.error(f"There is no subjob ID with ID:{subjob_id}")
					# AWS Batch requires that an array job have at least 2 elements,
					# sometimes we only need 1 though
					if(subjob_id == "1"):
						exit(0)
					else:
						raise RuntimeError(f"There is no subjob ID with ID:{subjob_id}")

		except Exception as err:
			logging.error(f"Cannot open {download_to_workunit_file}: {str(err)}")
			raise

		ctx['main_config']['job_object'] = job_object
		ctx['main_config']['job_bucket'] = job_bucket

	elif(ctx['job_storage_mode'] == "sharedfs"):

		config_json = os.getenv('VFLP_CONFIG_JSON', "")
		workunit_json = os.getenv('VFLP_WORKUNIT_JSON', "")

		if(config_json == "" or workunit_json == ""):
			print("For VFLP_JOB_STORAGE_MODE=sharedfs, VFLP_CONFIG_JSON, VFLP_WORKUNIT_JSON must be set")
			exit(1)

		# load in the main config from the ENV
		try:
			with open(config_json, 'rt') as f:
				config = json.load(f)
				ctx['main_config'] = config
		except Exception as err:
			logging.error(f"Cannot open {config_json}: {str(err)}")
			raise

		# Load workunit information
		try:
			with gzip.open(workunit_json, 'rt') as f:
				subjob_config = json.load(f)
				if(subjob_id in subjob_config['subjobs']):
					ctx['subjob_config'] = subjob_config['subjobs'][subjob_id]
				else:
					logging.error(f"There is no subjob ID with ID:{subjob_id} in {workunit_id}")
					raise RuntimeError(f"There is no subjob ID with ID:{subjob_id} in {workunit_id}")

		except Exception as err:
			logging.error(f"Cannot open {workunit_json}: {str(err)}")
			raise

		# Set paths used later by the sharedfs mode
		ctx['workflow_dir'] = ctx['main_config']['sharedfs_workflow_path']
		ctx['collection_dir'] = ctx['main_config']['sharedfs_collection_path']

	else:
		raise RuntimeError(f"Invalid jobstoragemode of {ctx['job_storage_mode']}. VFLP_JOB_STORAGE_MODE must be 's3' or 'sharedfs' ")




# Get only the collection information with the subjob specified

def get_workunit_from_s3(ctx, workunit_id, subjob_id, job_bucket, job_object, workunit_file):
	try:
		with open(workunit_file, 'wb') as f:
			ctx['s3'].download_fileobj(job_bucket, job_object, f)
	except botocore.exceptions.ClientError as error:
		logging.error(f"Failed to download from S3 {job_bucket}/{job_object} to {workunit_file}, ({error})")
		raise




def process(ctx):

	# Figure out what job we are running

	ctx['vcpus_to_use'] = int(os.getenv('VFLP_VCPUS', 1))
	ctx['run_sequential'] = int(os.getenv('VFLP_RUN_SEQUENTIAL', 0))

	workunit_id, subjob_id =  get_workunit_information()

	# This includes all of the configuration information we need
	# After this point ctx['main_config'] has the configuration options
	# and we have specific subjob information in ctx['subjob_config']

	get_subjob_config(ctx, workunit_id, subjob_id)

	# Setup the Nailgun server [only setup if needed]

	if(is_nailgun_needed(ctx)):
		ng_port = get_free_port()
		ng_host = os.getenv('VFLP_HOST', 'localhost')
		ng_process = start_ng_server(ng_host, ng_port, ctx['main_config']['java_max_heap_size'])
		ctx['main_config']['nailgun_port'] = str(ng_port)
		ctx['main_config']['nailgun_host'] = str(ng_host)
		atexit.register(cleanup_ng, ng_process)

	# Get information about the versions of the software
	# being used in the calculations
	get_helper_versions(ctx)

	# Run all of the collections. Do these in series to limit the amount of
	# storage needed until we push back to the filesystem or S3

	for collection_key in ctx['subjob_config']['collections']:
		collection = ctx['subjob_config']['collections'][collection_key]
		collection_data = get_collection_data(ctx, collection_key)
		process_collection(ctx, collection_key, collection, collection_data)




def process_collection(ctx, collection_key, collection, collection_data):

	collection_temp_dir = tempfile.TemporaryDirectory(prefix=ctx['temp_path'])

	tasklist = []

	for ligand_key in collection_data['ligands']:
		ligand = collection_data['ligands'][ligand_key]

		task = {
			'collection_key': collection_key,
			'metatranche': collection['metatranche'],
			'tranche': collection['tranche'],
			'collection_name': collection['collection_name'],
			'ligand_key': ligand_key,
			'ligand': ligand,
			'config': ctx['main_config'],
			'collection_temp_dir': collection_temp_dir,
			'main_temp_dir': ctx['temp_dir'],
			'versions': ctx['versions'],
			'temp_path': ctx['temp_path'],
			'store_all_intermediate_logs': ctx['main_config']['store_all_intermediate_logs']
		}

		tasklist.append(task)

	start_time = datetime.now()

	res = []

	if(ctx['run_sequential'] == 1):
		for taskitem in tasklist:
			res.append(process_ligand(taskitem))
	else:
		with multiprocessing.Pool(processes=ctx['vcpus_to_use']) as pool:
			res = pool.map(process_ligand, tasklist)

	end_time  = datetime.now()
	difference_time = end_time - start_time

	print(f"time difference is: {difference_time.seconds} seconds")


	# For each completed task, summarize the data into data
	# structures that we can save for later processing
	# and analysis

	unit_failed_count = 0
	unit_success_count = 0
	tautomer_failed_count = 0
	tautomer_success_count = 0

	collection_summary = { 'ligands': {}, 'seconds': difference_time.seconds }


	# Generate summaries based on collection from each of the results

	for task_result in res:

		ligand_key = task_result['base_ligand']['key']

		collection_summary['ligands'][ligand_key] = {
			'timers': task_result['base_ligand']['timers'],
			'status': task_result['status'],
			'status_sub': task_result['base_ligand']['status_sub'],
			'tautomers': task_result['ligands'],
			'stereoisomers': task_result['stereoisomers'],
		}
		collection_summary['ligands'][ligand_key]['seconds'] = task_result['seconds']

		# Remove fields we do not need from the output
		for tautomer_key, tautomer in collection_summary['ligands'][ligand_key]['tautomers'].items():
			tautomer.pop('intermediate_dir','')
			tautomer.pop('pdb_file','')


	move_list = []

	# Generate the status file
	status_file = generate_collection_summary_file(collection, collection_temp_dir, collection_summary)
	status_file_remote = generate_remote_path(ctx, collection, output_type="status", output_format="json.gz")

	move_item = {
		'local_path': status_file.as_posix(),
		'remote_path': status_file_remote
	}

	move_list.append(move_item)


	# Save the output files from the calculations to
	# the location listed in the configuration file
	#
	# In all cases the data is tar.gz for folders


	# Process each target format into a separate file
	for target_format in ctx['main_config']['target_formats']:

		local_path_dir = [
			collection_temp_dir.name,
			"complete",
			target_format,
			collection['metatranche'],
			collection['tranche'],
			collection['collection_name']
		]

		# In some cases we may not generate any output (for example if
		# all ligands in a collection fail)
		try:
			tar_gz_path = generate_tarfile("/".join(local_path_dir))

			move_item = {
				'local_path': tar_gz_path,
				'remote_path': generate_remote_path(ctx, collection, output_type=target_format, output_format="tar.gz")
			}

			move_list.append(move_item)
			print(move_item)
		except FileNotFoundError as error:
			logging.error(f"Could not create tarball from {local_path_dir}")



	# We may want to save the intermediate data for debugging

	if(ctx['main_config']['store_all_intermediate_logs'] == "true"):
		logging.error("Saving intermediate logs")
		for collection_key, collection in ctx['subjob_config']['collections'].items():

			local_path_dir = [
				collection_temp_dir.name,
				"intermediate",
				collection['metatranche'],
				collection['tranche'],
				collection['collection_name']
			]

			# In some cases we may not generate any output (for example if
			# all ligands in a collection fail)
			try:
				tar_gz_path = generate_tarfile("/".join(local_path_dir))

				move_item = {
					'local_path': tar_gz_path,
					'remote_path': generate_remote_path(ctx, collection, output_type="intermediate", output_format="tar.gz")
				}

				move_list.append(move_item)
				print(move_item)
			except FileNotFoundError as error:
				logging.error(f"Could not create tarball from {local_path_dir}")


	print(move_list)

	for move_item in move_list:
		move_file(ctx, move_item)



def move_file(ctx, move_item):

	if(ctx['job_storage_mode'] == "s3"):
		print(f"moving |{move_item['local_path']}| to |{move_item['remote_path']}| - bucket:{ctx['main_config']['job_bucket']}")
		try:
			response = ctx['s3'].upload_file(move_item['local_path'], ctx['main_config']['job_bucket'], move_item['remote_path'])
		except botocore.exceptions.ClientError as e:
			logging.error(e)
			raise
	elif(ctx['job_storage_mode'] == "sharedfs"):
		print(f"moveitem_local: {move_item['remote_path']}")

		local_file_path = Path(move_item['remote_path'])
		local_file_parent = local_file_path.parent.absolute()
		local_file_parent.mkdir(parents=True, exist_ok=True)

		print(f"{local_file_path.name} -> parent: {local_file_parent.name}")

		shutil.copyfile(move_item['local_path'], move_item['remote_path'])


def generate_remote_path(ctx, collection, output_type="status", output_format="json.gz"):

	if(ctx['job_storage_mode'] == "s3"):
		base_prefix = ctx['main_config']['object_store_job_output_data_prefix_full']
	elif(ctx['job_storage_mode'] == "sharedfs"):
		base_prefix = ctx['workflow_dir']


	if(ctx['main_config']['job_storage_output_addressing'] == "hash"):
		collection_string = f"{collection['metatranche']}_{collection['tranche']}_{collection['collection_name']}"
		hash_string = get_collection_hash(collection_string)

		prefix_components = [
			base_prefix,
			hash_string[0:2],
			hash_string[2:4],
		]
	else:
		prefix_components = [
			base_prefix
		]

	prefix = "/".join(prefix_components)


	if(output_format == "json.gz"):
		remote_dir = [
			prefix,
			"complete",
			output_type,
			collection['metatranche'],
			collection['tranche'],
		]

		# Remote path
		return "/".join(remote_dir) + f"/{collection['collection_name']}.json.gz"

	elif(output_format == "tar.gz"):
		collection_path = [
			prefix,
			"complete",
			output_type,
			collection['metatranche'],
			collection['tranche'],
			collection['collection_name']
		]

		return"/".join(collection_path) + ".tar.gz"
	else:
		raise RuntimeError(f"Invalid value of output_format ({output_format})")

def generate_collection_summary_file(collection, collection_temp_dir, collection_summary):

	temp_dir = Path(collection_temp_dir.name)
	status_dir = temp_dir / "complete" / "status" / collection['metatranche'] / collection['tranche']
	status_dir.mkdir(parents=True, exist_ok=True)

	status_file = status_dir / f"{collection['collection_name']}.json.gz"

	with gzip.open(status_file, "wt") as json_gz:
		json.dump(collection_summary, json_gz)

	return status_file


def get_collection_data(ctx, collection_key):

	collection = ctx['subjob_config']['collections'][collection_key]

	collection_data = {}
	collection_data['ligands'] = {}

	# subjob_config
	# 	collections (collection_key)
	#		metatranche
	#		tranche
	#		collection_name
	#
	#		s3_bucket
	#		s3_download_path
	#
	#		fieldnames [headers for collection file]
	#

	# The collection obj will have information on where it is located
	# Use that to create the directory (if not already created)


	if(ctx['job_storage_mode'] == "s3"):

		temp_dir = Path(ctx['temp_dir'].name)
		download_dir = temp_dir / collection['metatranche'] / collection['tranche']
		download_dir.mkdir(parents=True, exist_ok=True)

		collection_file = download_dir / f"{collection['collection_name']}.txt.gz"
		try:
			with collection_file.open(mode = 'wb') as f:
				ctx['s3'].download_fileobj(collection['s3_bucket'], collection['s3_download_path'], f)
		except botocore.exceptions.ClientError as error:
			logging.error(f"Failed to download from S3 {collection['s3_bucket']}/{collection['s3_download_path']} to {str(collection_file)}, ({error})")
			raise

	elif(ctx['job_storage_mode'] == "sharedfs"):
		collection_file = Path(ctx['collection_dir']) / collection['metatranche'] / collection['tranche'] /  f"{collection['collection_name']}.txt.gz"


	# Read in the collection data (regardless of source)

	try:
		with gzip.open(collection_file, 'rt') as f:
			reader = csv.DictReader(f, fieldnames=collection['fieldnames'], delimiter='\t')
			for row in reader:
				ligand_key = row['ligand-name']
				collection_data['ligands'][ligand_key] = {
					'smi': row['smi'],
					'file_data': row
				}

	except Exception as err:
		logging.error(f"Cannot open {str(collection_file)}: {str(err)}")
		raise

	return collection_data


def main():

	logging.basicConfig(level=logging.ERROR)

	ctx = {}

	ret = subprocess.run(['df', '-h'], capture_output=True, text=True)
	if ret.returncode == 0:
		print(ret.stdout)
	else:
		print("could not run df -h")

	aws_region = os.getenv('VFLP_REGION', "us-east-1")

	botoconfig = Config(
	   region_name = aws_region,
	   retries = {
	      'max_attempts': 15,
	      'mode': 'standard'
	   }
	)

	# Get the config information
	ctx['s3'] = boto3.client('s3', config=botoconfig)

	tmp_path = os.getenv('VFLP_TMP_PATH', "/tmp")
	tmp_path = os.path.join(tmp_path, '')

	ctx['temp_path'] = tmp_path
	ctx['temp_dir'] = tempfile.TemporaryDirectory(prefix=tmp_path)

	process(ctx)

	print("end")
	ret = subprocess.run(['df', '-h'], capture_output=True, text=True)
	if ret.returncode == 0:
		print(ret.stdout)
	else:
		print("could not run df -h")

if __name__ == '__main__':
    main()







