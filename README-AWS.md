
## Getting Started with VirtualFlow

This initial setup is required when either VirtualFlow VFLP or VFVS is used. The same AWS setup can be used for both workflows, so it does not need to be duplicated if it is already deployed.

### Create an S3 bucket for data (input and output)

The instructions for this are not covered in this document, but can be found on the [AWS website](https://docs.aws.amazon.com/AmazonS3/latest/userguide/create-bucket-overview.html). As a general best practice, this bucket should not have any public access enabled.


### Set up the AWS CloudFormation Templates

AWS CloudFormation templates allow us to describe infrastructure as code and this allows a setup to be re-created simply. A sample CloudFormation template has been provided in `cfn` in th [VFVS repository](https://github.com/VirtualFlow/VFVS). You may choose to setup these in an alternative way, but the template can provide a guide on permissions needed.

Edit `vf-parameters.json` to ensure you have the appropriate S3 parameter (S3BucketName) and KeyName. The S3BucketName is the name of the bucket created in the previous step. The KeyName refers to the EC2 SSH key that you will use to login to the main node that this creates.

```bash
cd cfn/
# Create a large VPC for VirtualFlow (built for us-east-1)
bash create-vf-vpc.sh
# Create the VirtualFlow specific resources
bash create-vf.sh
```

Wait for it to be completed:
```bash
aws cloudformation describe-stacks --stack-name vf --query "Stacks[0].StackStatus"
```




## Getting Started with VirtualFlow Ligand Preparation (VFLP)


```

#### Login to the Main Instance

The template above will generate an instance that will be used to run VFLP/VFVS components. The actual execution will occur in AWS Batch, however, this instance allows staging data, building the docker image, and storing information about the specific VFLP job running.

The following command and example output show how to retrieve the login hostname for the created instance.
```bash
aws cloudformation describe-stacks --stack-name vflp --query "Stacks[0].Outputs"

[
    {
        "Description": "Public DNS name for the main node", 
        "ExportName": "vflp-MainNodePublicDNS", 
        "OutputKey": "MainNodePublicDNS", 
        "OutputValue": "ec2-XX-XXX-XXX-XX.compute-1.amazonaws.com"
    }
]
```

You will need to login with the SSH key that was specified as part of the CloudFormation parameters. e.g.

```bash
ssh ec2-user@ec2-<login node>.amazonaws.com -i ~/.ssh/keyname.pem 
```

#### Install VFLP

```bash
git clone https://github.com/VirtualFlow/VFLP.git
cd VFLP
```

#### Update the configuration file

The file is in `tools/templates/all.ctrl` and the options are documented in the file itself. A few of the AWS-specific configuration options are listed below:

Job Configuration:

- `batchsystem`: Set this to `awsbatch` if you are running with AWS Batch
- `threads_to_use`: Set this to the number of threads cores that a single job should use.
- `job_storage_mode`: When using AWS Batch, this must be set to `s3`. Data will be stored in an S3 bucket

Slurm-specific Configuration:

- `aws_batch_prefix`: Prefix for the name of the AWS Batch queues. This is normally 'vf' if you used the provided CloudFormation template
- `aws_batch_number_of_queues`: Should be set to the number of queues that are setup for AWS Batch. Generally this number is 2 unless you have a large-scale (100K+ vCPUs) setup
- `aws_batch_jobdef`: Generally this is [aws_batch_prefix]-jobdef-vflp
- `aws_batch_array_job_size`: Target for the number of jobs that should be in a single array job for AWS Batch.
- `aws_ecr_repository_name`: Set it to the name of the Elastic Container Registry (ECR) repository (e.g. vf-vflp-ecr) in your AWS account (If you used the template it is generally vf-vflp-ecr)
- `aws_region`: Set to the AWS location code where you are running AWS Batch (e.g. us-east-1 for North America, Northern Virginia)
- `aws_batch_subjob_vcpus`: Set to the number of vCPUs that should be launched per subjob. 'threads_to_use' above should be >= to this value.
- `aws_batch_subjob_memory`: Memory per subjob to setup for the container in MB.
- `aws_batch_subjob_timeout`: Maximum amount of time (in seconds) that a single AWS Batch job should ever run before being terminated.


Job-sizing:

- `ligands_todo_per_queue`: This determines how many ligands should be processed at a minimum per job. A value of '10000' would mean that each subjob with `aws_batch_subjob_vcpus` number of CPUs should process this number of ligands prior to completing. In general jobs should run for approximately 30 minutes or more. How long each ligand will take will depend on the settings provided and tools used. Submitting a small job (a few thousand ligands) to determine how long processing will take is often a good idea to size these before large runs.


### Data for Virtual Screening

The location of the collection files to be used in the screening should be located in the S3 bucket (defined in `all.ctrl`).

VFLP expects that collection data will be stored in a prefix structure in the format of `[a-zA-AZ]+/[a-zA-AZ]+/[a-zA-AZ].txt`. Assuming a path to a collection of ligands is `a/b/c.txt` the corresponding entry in the `todo.all` will be `a_b_c 1000` (where 1000 is the number of ligands in that particular file).


### Run a Job

#### Prepare Workflow

```bash
cd tools
./vflp_prepare_folders.py
```

If you have previously setup a job in this directory the command will let you know that it already exists. If you are sure you want to delete the existing data, then run with `--overwrite`.

Once you run this command the workflow is defined using the current state of all.ctrl and todo.all. Changes to those files at this point will not be used unless vflp_prepare_folders.py is run again.

#### Build Docker Image (first time only)

This is only required once (or if files have been changed and need to be updated). This will prepare the container that AWS Batch will use to run VFLP

```bash
./vflp_build_docker.sh
```


#### Generate Workunits

VFLP can process billions of ligands and in order to process these efficiently it is helpful to segment this work into smaller chunks. A workunit is a segment of work that contains many 'subjobs' that are the actual execution elements. Often a workunit will have approximately 200 subjobs and each subjob will contain about 60 minutes worth of computation.

```bash
./vflp_prepare_workunits.py
```

Pay attention to how many workunits are generated. The final line of output will provide the number of workunits.

#### Submit the job to run on AWS Batch


The following command will submit workunits 1 and 2. The default configuration with 
AWS Batch will use 200 subjobs per workunit, so this will submit 2x200 (400) subjobs
(assuming that each workunit was full)

```bash
./vflp_submit_jobs.py 1 2
```

Once submitted, AWS Batch will start scaling up resources to meet the requirements of the jobs.

#### Monitor Progress

The following command will show the progress of the jobs in AWS Batch. RUNNABLE means that the resources are not yet available for the job to run. 'RUNNING' means the work is currently being processed.

```bash
./vflp_get_status.py
```

The following is example output:
```bash
Looking for updated jobline status - starting

Looking for updated jobline status - done

Looking for updated subtask status - starting

Looking for updated subtask status - done
Generating summary
SUMMARY BASED ON AWS BATCH COMPLETION STATUS (different than actual processing status):

      category     SUBMITTED       PENDING      RUNNABLE      STARTING       RUNNING     SUCCEEDED        FAILED         TOTAL
       ligands             0             0        630000          2000         44000             0             0        676000
          jobs             0           169             0             0             0             0             0           169
       subjobs             0             0           315             1            22             0             0           338
    vcpu_hours             -             -             -             -             -          0.00          0.00          0.00

vCPU hours total: 0.00
vCPU hours interrupted: 0.00

Active vCPUs: 176
Writing the json status file out - Do not interrupt!
```

After completion, it will also provide information on vCPU seconds that were used per ligand. "vCPU hours interrupted" refers to how many vCPU hours were lost to EC2 Spot reclaimations that may have occurred during the run (if you are using EC2 Spot).


#### Monitor Progress (Details of Single Workunit)

```bash
./vflp_get_details.py <workunit id>
```

This provides information on what specifically occurred for the collections included in the specified workunit

```bash
[ec2-user@ip-172-31-56-4 tools]$ ./vflp_get_details.py 1
virtualflow-data:jobs/vflp/vcpu8-X/complete/status/qa/a/a.json.gz
1:0: original: 1000, expanded: 1134, successful: 1134
protonation: 1134, failed: 0
tranche-assignment: 1134, failed: 0
conformation: 1134, failed: 0
energy-check: 1134, failed: 0
targetformat-generation(pdb): 1134, failed: 0
targetformat-generation(pdbqt): 1134, failed: 0
targetformat-generation(sdf): 1134, failed: 0
targetformat-generation(mol2): 1134, failed: 0
targetformat-generation(smi): 1134, failed: 0
```

#### Job Output

Output will be in `s3://<job_bucket>/<job_prefix>/complete/`
 * `complete/status` includes the status files with summary information
 * `complete/<format>` includes the output ligands in each respective format that was requested in the configuration file


### Tips and Advice

If for any reason all of the AWS Batch jobs need to be stopped (a misconfiguration, etc), the `tools/util/aws_batch_kill_all.sh` script can be used to cancel all AWS Batch jobs running in the account. NOTE: This is not specific to the VFLP job, but all running AWS Batch jobs in the account.





