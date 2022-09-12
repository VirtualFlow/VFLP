
## Getting Started with VirtualFlow Ligand Preparation (VFLP) with Slurm


VFLP requires Python 3.x (it has been tested with Python 3.9.4). Additionally, it requires packages to be installed that are not included at many sites. As a result, we recommend that you create a virtualenv for VFLP that can be used to run jobs.

Make sure that virtualenv is installed:
```bash
python3 -m pip install --user --upgrade virtualenv
```

Create a virtualenv (this example creates it under $HOME/vflp_env):
```bash
python3 -m virtualenv $HOME/vflp_env
```

Enter the virtualenv and install needed packages
```bash
source $HOME/vflp_env/bin/activate
python3 -m pip install boto3 jinja2
```

To exit a virtual environment:
```bash
deactivate
```

When running VFLP commands, you should enter the virtualenv that you have setup using:
```bash
source $HOME/vflp_env/bin/activate
```

As noted later, you will want to include this virtualenv as part of the Slurm script that VFLP runs for a job.

#### Open Babel

Open Babel 2.x is required for VFLP. It expects that the Open Babel commands are in your path. If it is not in the standard path, you will need to update the Slurm job template file.

#### Install VFLP

```bash
git clone https://github.com/VirtualFlow/VFLP.git
cd VFLP
```

#### Update the configuration file

The file is in `tools/templates/all.ctrl` and the options are documented in the file itself. A few of the Slurm-specific configuration options are listed below:

Job Configuration:

- `batchsystem`: Set this to `slurm` if you are running with the Slurm Workload Manager scheduler
- `threads_to_use`: Many Slurm clusters are configured so a single job consumes an entire node; if that is the case, set this value to the number of cores on the compute node that VFLP will be run on. (This will generally be the same as `slurm_cpus` below.)
- `job_storage_mode`: When using Slurm, this must be set to `sharedfs`. This setting means that the data (input collections and output) is on a shared filesystem that can be seen across all nodes. This may be a scratch directory.

Slurm-specific Configuration:

- `slurm_template`: This is the path to the template file that will be used to submit the invidual jobs that VFLP submits to slurm. Use this to set specific options that may be required by your site. This could include setting an account number, specific partition, etc. Note: Please update this to include the virtualenv that you setup earlier (if needed)
- `slurm_array_job_size`: How many jobs can be run in a single array job. (The default for a Slurm scheduler is 1000, so unless your site has changed it then the limit will likely be this)
- `slurm_array_job_throttle`: VFLP uses Slurm array jobs to more efficiently submit the jobs.  This setting limits how many jobs from a single job array run could be run at the same time. Setting `slurm_array_job_throttle` to `slurm_array_job_size` means there will be no throttling.
- `slurm_partition`: Name of slurm partition to submit to
- `slurm_cpus`: Number of compute cores that should be requested per job.

Job-sizing:

- `ligands_todo_per_queue`: This determines how many ligands should be processed at a minimum per job. A value of '10000' would mean that each subjob with `aws_batch_subjob_vcpus` number of CPUs should process this number of ligands prior to completing. In general jobs should run for approximately 30 minutes or more. How long each ligand will take will depend on the settings provided and tools used. Submitting a small job (a few thousand ligands) to determine how long processing will take is often a good idea to size these before large runs.

### Data for Virtual Screening

The location of the collection files to be used in the screening should be located in `collection_folder` (defined in `all.ctrl`).

VFLP expects that collection data will be stored in a directory structure in the format of `[a-zA-AZ]+/[a-zA-AZ]+/[a-zA-AZ].txt`. Assuming a path to a collection of ligands is `a/b/c.txt` the corresponding entry in the `todo.all` will be `a_b_c 1000` (where 1000 is the number of ligands in that particular file).

### Run a Job

#### Prepare Workflow

```bash
cd tools
./vflp_prepare_folders.py
```

If you have previously setup a job in this directory the command will let you know that it already exists. If you are sure you want to delete the existing data, then run with `--overwrite`.

Once you run this command the workflow is defined using the current state of all.ctrl and todo.all. Changes to those files at this point will not be used unless vflp_prepare_folders.py is run again.

#### Generate Workunits

VFLP can process billions of ligands and in order to process these efficiently it is helpful to segment this work into smaller chunks. A workunit is a segment of work that contains many 'subjobs' that are the actual execution elements. Often a workunit will have approximately 200 subjobs and each subjob will contain about 60 minutes worth of computation.

```bash
./vflp_prepare_workunits.py
```

Pay attention to how many workunits are generated. The final line of output will provide the number of workunits.

#### Submit the job to run on Slurm


The following command will submit workunits 1 and 2. The default configuration with
Slurm will use 200 subjobs per workunit, so this will submit 2x200 (400) subjobs
(assuming that each workunit was full). Each subjob takes `slurm_cpus` cores when running.

How long each job takes will be dependent on the parameters that were set as part of the `all.ctrl` and the docking scenarios themselves.

```bash
./vflp_submit_jobs.py 1 2
```

Once submitted, the jobs will be visible in the Slurm queue (`squeue`)

#### Monitor Progress

At present, the only way to monitor progress of jobs will be to check status through the Slurm scheduler commands. This will be extended in the future to more natively track progress towards completion.

The output of specific workunits can be found under: `../workflow/workunits/<workunit_id>/`


#### Job Output

Output will be in `../workflow/complete/`
 * `complete/status` includes the status files with summary information
 * `complete/<format>` includes the output ligands in each respective format that was requested in the configuration file








