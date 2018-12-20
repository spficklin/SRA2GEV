#!/usr/bin/env nextflow

/**
 * ========
 * GEMmaker
 * ========
 *
 * Authors:
 *  + John Hadish
 *  + Tyler Biggs
 *  + Stephen Ficklin
 *  + Ben Shealy
 *  + Connor Wytko
 *
 * Summary:
 *   A workflow for processing a large amount of RNA-seq data
 */



println """\

===================================
 G E M M A K E R   P I P E L I N E
===================================

General Information:
--------------------
  Profile(s):         ${workflow.profile}
  Container Engine:   ${workflow.containerEngine}


Input Parameters:
-----------------
  Remote fastq list path:     ${params.input.remote_list_path}
  Local sample glob:          ${params.input.local_samples_path}
  Reference genome path:      ${params.input.reference_path}
  Reference genome prefix:    ${params.input.reference_prefix}


Output Parameters:
------------------
  Output directory:           ${params.output.dir}


Software Parameters:
--------------------
  Trimmomatic clip path:      ${params.software.trimmomatic.clip_path}
  Trimmomatic minimum ratio:  ${params.software.trimmomatic.MINLEN}


Publishing Files:
-----------------
  Trimmed FASTQ files:  ${params.publish.keep_trimmed_fastq}
  BAM Alignment files:  ${params.publish.keep_alignment_bam}

"""

/**
 * Create value channels that can be reused
 */
HISAT2_INDEXES = Channel.fromPath("${params.input.reference_path}/${params.input.reference_prefix}*.ht2*").collect()
GTF_FILE = Channel.fromPath("${params.input.reference_path}/${params.input.reference_prefix}.gtf").collect()


/**
 * Local Sample Input.
 * This checks the folder that the user has given
 */
if (params.input.local_samples_path == "none") {
  Channel
    .empty()
    .set { LOCAL_SAMPLES }
} else {
  Channel
    .fromFilePairs( params.input.local_samples_path, size: -1 )
    .set { LOCAL_SAMPLES }
}

/**
 * Set the pattern for publishing trimmed files
 */
trimmomatic_publish_pattern = "*.trim.log";
if (params.publish.keep_trimmed_fastq == true) {
  trimmomatic_publish_pattern = "{*.trim.log,*_trim.fastq}";
}

/**
 * Set the pattern for publishing BAM files
 */
samtools_sort_publish_pattern = "*.log";
if (params.publish.keep_alignment_bam == true) {
  samtools_sort_publish_pattern = "*.bam";
}
samtools_index_publish_pattern = "*.log";
if (params.publish.keep_alignment_bam == true) {
  samtools_index_publish_pattern = "{*.log,*.bam.bai}";
}

/**
 * Remote fastq_run_id Input.
 */
if (params.input.remote_list_path == "none") {
  Channel
     .empty()
     .set { REMOTE_FASTQ_RUNS }
} else {
  Channel
    .from( file(params.input.remote_list_path).readLines() )
    .set { REMOTE_FASTQ_RUNS }
}



/**
 * The fastq dump process downloads any needed remote fasta files to the
 * current working directory.
 */
process fastq_dump {
  // module "sratoolkit"
  // time params.software.fastq_dump.time
  tag { fastq_run_id }
  label "sratoolkit"
  label "retry"

  input:
    val fastq_run_id from REMOTE_FASTQ_RUNS

  output:
    set val(fastq_run_id), file("${fastq_run_id}_?.fastq") into DOWNLOADED_FASTQ_RUNS

  """
  fastq-dump --split-files $fastq_run_id
  """
}

/**
 * Combine the remote and local samples into the same channel.
 */
COMBINED_SAMPLES = DOWNLOADED_FASTQ_RUNS.mix( LOCAL_SAMPLES )


/**
 * Performs a SRR/DRR/ERR to sample_id converison:
 *
 * This first checks to see if the format is standard SRR,ERR,DRR
 * This takes the input SRR numbersd and converts them to sample_id.
 * This is done by a python script that is stored in the "scripts" dir
 * The next step combines them
 */
process SRR_to_sample_id {
  // module "anaconda3"
  // module "python3"
  tag { fastq_run_id }
  label "python3scripts"
  label "rate_limit"

  input:
    set val(fastq_run_id), file(pass_files) from COMBINED_SAMPLES

  output:
    set stdout, file(pass_files) into GROUPED_BY_SAMPLE_ID mode flatten

  """
  if [[ "$fastq_run_id" == [SDE]RR* ]]; then
    python3 ${PWD}/scripts/retrieve_sample_metadata.py $fastq_run_id

  else
    echo -n "Sample_$fastq_run_id"
  fi
  """
}



/**
 * This groups the channels based on sample_id.
 */
GROUPED_BY_SAMPLE_ID
  .groupTuple()
  .set { GROUPED_SAMPLE_ID }



/**
 * This process merges the fastq files based on their sample_id number.
 */
process SRR_combine {
  tag { sample_id }

  input:
    set val(sample_id), file(grouped) from GROUPED_SAMPLE_ID
  output:
    set val(sample_id), file("${sample_id}_?.fastq") into MERGED_SAMPLES
    set val(sample_id), file("${sample_id}_?.fastq") into MERGED_SAMPLES_FOR_FASTQC_1

  /**
   * This command tests to see if ls produces a 0 or not by checking
   * its standard out. We do not use a "if [-e *foo]" becuase it gets
   * confused if there are more than one things returned by the wildcard
   */
  """
    if ls *_1.fastq >/dev/null 2>&1; then
      cat *_1.fastq >> "${sample_id}_1.fastq"
    fi

    if ls *_2.fastq >/dev/null 2>&1; then
      cat *_2.fastq >> "${sample_id}_2.fastq"
    fi
  """
}



/**
 * Performs fastqc on fastq files prior to trimmomatic
 */
process fastqc_1 {
  // module "fastQC"
  // time params.software.fastqc_1.time
  publishDir params.output.sample_dir, mode: 'symlink', pattern: "*_fastqc.*"
  tag { sample_id }
  label "fastqc"

  input:
    set val(sample_id), file(pass_files) from MERGED_SAMPLES_FOR_FASTQC_1

  output:
    set file("${sample_id}_?_fastqc.html") , file("${sample_id}_?_fastqc.zip") optional true into FASTQC_1_OUTPUT

  """
  fastqc $pass_files
  """
}

/**
  * THIS IS WHERE THE SPLIT HAPPENS FOR hisat2 vs Kallisto vs Salmon
  *
  * Information about "choice" split operator (to be deleted before final
  * GEMmaker release)
 */

HISAT2_CHANNEL = Channel.create()
KALLISTO_CHANNEL = Channel.create()
SALMON_CHANNEL  = Channel.create()
MERGED_SAMPLES.choice( HISAT2_CHANNEL, KALLISTO_CHANNEL, SALMON_CHANNEL) { params.software.alignment.which_alignment }


/**
 * Performs KALLISTO alignemnt of fastq files
 *
 *
 */
 process kallisto {
   // module "kallisto"
   publishDir params.output.sample_dir, mode: 'symlink'
   tag { sample_id }
   label "kallisto"

   input:
     set val(sample_id), file(pass_files) from KALLISTO_CHANNEL
     //file reference from file("${params.input.reference_path}/*").toList()
     file kallisto_index from file("${params.input.reference_path}/${params.input.reference_prefix}.transcripts.Kallisto.indexed")

   output:
     set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") into KALLISTO_GA

   script:
   """
   if [ -e ${sample_id}_2.fastq ]; then
    kallisto quant \
      -i  ${params.input.reference_prefix}.transcripts.Kallisto.indexed \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      ${sample_id}_1.fastq \
      ${sample_id}_2.fastq



   else
     kallisto quant \
      --single \
      -l 70 \
      -s .0000001 \
      -i ${params.input.reference_prefix}.transcripts.Kallisto.indexed \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      ${sample_id}_1.fastq

   fi

   """
 }

 /**
  * Generates the final TPM file for Kallisto
  */
 process kallisto_tpm {
   publishDir params.output.sample_dir, mode: 'symlink'
   tag { sample_id }

   input:
     set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") from KALLISTO_GA

   output:
     file "${sample_id}_vs_${params.input.reference_prefix}.tpm" optional true into KALLISTO_TPM

   script:
     """
     awk -F"\t" '{if (NR!=1) {print \$1, \$5}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga/abundance.tsv > ${sample_id}_vs_${params.input.reference_prefix}.tpm
     """
 }




 /**
  * Performs SALMON alignemnt of fastq files
  *
  *
  */
  process salmon {
    // module "salmon"
    publishDir params.output.sample_dir, mode: 'symlink'
    tag { sample_id }
    label "salmon"

    input:
      set val(sample_id), file(pass_files) from SALMON_CHANNEL
      file salmon_index from Channel.fromPath("${params.input.reference_path}${params.input.reference_prefix}*/*").toList()


    output:
      set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") into SALMON_GA

    script:
    """



    if [ -e ${sample_id}_2.fastq ]; then
      salmon quant \
      -i . \
      -l A \
      -1 ${sample_id}_1.fastq \
      -2 ${sample_id}_2.fastq \
      -p 8 \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      --minAssignedFrags 1


    else
      salmon quant \
      -i . \
      -l A \
      -r ${sample_id}_1.fastq \
      -p 8 \
      -o ${sample_id}_vs_${params.input.reference_prefix}.ga \
      --minAssignedFrags 1

    fi

    """
  }

  /**
   * Generates the final TPM file for Salmon
   */
  process salmon_tpm {
    publishDir params.output.sample_dir, mode: 'symlink'
    tag { sample_id }

    input:
      set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") from SALMON_GA

    output:
      file "${sample_id}_vs_${params.input.reference_prefix}.tpm" optional true into SALMON_TPM

    script:
      """
      awk -F"\t" '{if (NR!=1) {print \$1, \$4}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga/quant.sf > ${sample_id}_vs_${params.input.reference_prefix}.tpm
      """
  }



/**
 * Performs Trimmomatic on all fastq files.
 *
 * This process requires that the ILLUMINACLIP_PATH environment
 * variable be set in the trimmomatic module. This indicates
 * the path where the clipping files are stored.
 *
 * MINLEN is calculated using based on percentage of the mean
 * read length. The percenage is determined by the user in the
 * "nextflow.config" file
 */
process trimmomatic {
   // module "trimmomatic"
   // time params.software.trimmomatic.time
   publishDir params.output.sample_dir, mode: 'symlink', pattern: trimmomatic_publish_pattern
   tag { sample_id }

   label "multithreaded"
   label "trimmomatic"


   input:
     set val(sample_id), file("${sample_id}_?.fastq") from HISAT2_CHANNEL

   output:
     set val(sample_id), file("${sample_id}_*trim.fastq") into TRIMMED_SAMPLES_FOR_FASTQC
     set val(sample_id), file("${sample_id}_*trim.fastq") into TRIMMED_SAMPLES_FOR_HISAT2
     set val(sample_id), file("${sample_id}_*trim.fastq") into TRIMMED_SAMPLES_2_CLEAN
     set val(sample_id), file("${sample_id}.trim.log") into TRIMMED_SAMPLE_LOG

   script:
     """
     #This script calculates average length of fastq files.
      total=0

      #This if statement checks if the data is single or paired data, and checks length accordingly
      #This script returns 1 number, which can be used for the minlen in trimmomatic
      if [ -e ${sample_id}_1.fastq ] && [ -e ${sample_id}_2.fastq ]; then
        for fastq in ${sample_id}_1.fastq ${sample_id}_2.fastq; do
          a=`awk 'NR%4 == 2 {lengths[length(\$0)]++} END {for (l in lengths) {print l, lengths[l]}}' \$fastq \
          | sort \
          | awk '{ print \$0, \$1*\$2}' \
          | awk '{ SUM += \$3 } { SUM2 += \$2 } END { printf("%.0f", SUM / SUM2 * ${params.software.trimmomatic.MINLEN})} '`
        total=(\$a + \$total)
        done
        total=( \$total / 2 )
        minlen=\$total

      elif [ -e ${sample_id}_1.fastq ]; then
        minlen=`awk 'NR%4 == 2 {lengths[length(\$0)]++} END {for (l in lengths) {print l, lengths[l]}}' ${sample_id}_1.fastq \
          | sort \
          | awk '{ print \$0, \$1*\$2}' \
          | awk '{ SUM += \$3 } { SUM2 += \$2 } END { printf("%.0f", SUM / SUM2 * ${params.software.trimmomatic.MINLEN})} '`
      fi



     if [ -e ${sample_id}_1.fastq ] && [ -e ${sample_id}_2.fastq ]; then
     // java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
      java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
        PE \
        -threads ${params.execution.threads} \
        ${params.software.trimmomatic.quality} \
        ${sample_id}_1.fastq \
        ${sample_id}_2.fastq \
        ${sample_id}_1p_trim.fastq \
        ${sample_id}_1u_trim.fastq \
        ${sample_id}_2p_trim.fastq \
        ${sample_id}_2u_trim.fastq \
        ILLUMINACLIP:${params.software.trimmomatic.clip_path}:2:40:15 \
        LEADING:${params.software.trimmomatic.LEADING} \
        TRAILING:${params.software.trimmomatic.TRAILING} \
        SLIDINGWINDOW:${params.software.trimmomatic.SLIDINGWINDOW} \
        MINLEN:"\$minlen" > ${sample_id}.trim.log 2>&1
     else
      # For ease of the next steps, rename the reverse file to the forward.
      # since these are non-paired it really shouldn't matter.
      if [ -e ${sample_id}_2.fastq ]; then
        mv ${sample_id}_2.fastq ${sample_id}_1.fastq
      fi
      # Now run trimmomatic
      java -Xmx512m org.usadellab.trimmomatic.Trimmomatic \
        SE \
        -threads ${params.execution.threads} \
        ${params.software.trimmomatic.quality} \
        ${sample_id}_1.fastq \
        ${sample_id}_1u_trim.fastq \
        ILLUMINACLIP:${params.software.trimmomatic.clip_path}:2:40:15 \
        LEADING:${params.software.trimmomatic.LEADING} \
        TRAILING:${params.software.trimmomatic.TRAILING} \
        SLIDINGWINDOW:${params.software.trimmomatic.SLIDINGWINDOW} \
        MINLEN:"\$minlen" > ${sample_id}.trim.log 2>&1
     fi
     """
}



/**
 * Performs fastqc on fastq files post trimmomatic
 * Files are stored to an independent folder
 */
process fastqc_2 {
  // module "fastQC"
  // time params.software.fastqc_2.time
  publishDir params.output.sample_dir, mode: 'symlink', pattern: "*_fastqc.*"
  tag { sample_id }
  label "fastqc"

  input:
    set val(sample_id), file(pass_files) from TRIMMED_SAMPLES_FOR_FASTQC

  output:
    set val(sample_id), file(pass_files) into TRIMMED_FASTQC_SAMPLES
    set file("${sample_id}_??_trim_fastqc.html"), file("${sample_id}_??_trim_fastqc.zip") optional true into FASTQC_2_OUTPUT

  """
  fastqc $pass_files
  """
}



/**
 * Performs hisat2 alignment of fastq files to a genome reference
 *
 * depends: trimmomatic
 */
process hisat2 {
  // time params.software.hisat2.time
  publishDir params.output.sample_dir, mode: 'symlink', pattern: "*.log"
  tag { sample_id }

  label "multithreaded"
  label "hisat2"

  input:
   set val(sample_id), file(input_files) from TRIMMED_SAMPLES_FOR_HISAT2
   file indexes from HISAT2_INDEXES
   file gtf_file from GTF_FILE

  output:
   set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam") into INDEXED_SAMPLES
   set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam.log") into INDEXED_SAMPLES_LOG
   set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam") into HISAT2_SAM_2_CLEAN
   set val(sample_id), val(1) into HISAT2_DONE_SAMPLES

  script:
   """
     if [ -e ${sample_id}_2p_trim.fastq ]; then
       hisat2 \
         -x ${params.input.reference_prefix} \
         --no-spliced-alignment \
         -q \
         -1 ${sample_id}_1p_trim.fastq \
         -2 ${sample_id}_2p_trim.fastq \
         -U ${sample_id}_1u_trim.fastq,${sample_id}_2u_trim.fastq \
         -S ${sample_id}_vs_${params.input.reference_prefix}.sam \
         -t \
         -p ${params.execution.threads} \
         --un ${sample_id}_un.fastq \
         --dta-cufflinks \
         --new-summary \
         --summary-file ${sample_id}_vs_${params.input.reference_prefix}.sam.log
     else
       hisat2 \
         -x ${params.input.reference_prefix} \
         --no-spliced-alignment \
         -q \
         -U ${sample_id}_1u_trim.fastq \
         -S ${sample_id}_vs_${params.input.reference_prefix}.sam \
         -t \
         -p ${params.execution.threads} \
         --un ${sample_id}_un.fastq \
         --dta-cufflinks \
         --new-summary \
         --summary-file ${sample_id}_vs_${params.input.reference_prefix}.sam.log
     fi
   """
}



/**
 * Sorts the SAM alignment file and coverts it to binary BAM
 *
 * depends: hisat2
 */
process samtools_sort {
  // module "samtools"
  // time params.software.samtools_sort.time
  publishDir params.output.sample_dir, mode: 'symlink', pattern: samtools_sort_publish_pattern
  tag { sample_id }
  label "samtools"


  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.sam") from INDEXED_SAMPLES

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") into SORTED_FOR_INDEX
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") into SAMTOOLS_SORT_BAM_2_CLEAN
    set val(sample_id), val(1) into SAMTOOLS_SORT_DONE_SAMPLES

    // samtools sort -o ${sample_id}_vs_${params.input.reference_prefix}.bam -O bam ${sample_id}_vs_${params.input.reference_prefix}.sam

  script:
    """
    samtools sort -o ${sample_id}_vs_${params.input.reference_prefix}.bam -O bam ${sample_id}_vs_${params.input.reference_prefix}.sam -T temp
    """
}



/**
 * Indexes the BAM alignment file
 *
 * depends: samtools_index
 */
process samtools_index {
  // module "samtools"
  // time params.software.samtools_index.time
  publishDir params.output.sample_dir, mode: 'symlink', pattern: samtools_index_publish_pattern
  tag { sample_id }
  label "samtools"

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") from SORTED_FOR_INDEX

  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") into BAM_INDEXED_FOR_STRINGTIE
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam.bai") into BAI_INDEXED_FILE
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam.log") into BAM_INDEXED_LOG

  script:
    """
    samtools index ${sample_id}_vs_${params.input.reference_prefix}.bam
    samtools stats ${sample_id}_vs_${params.input.reference_prefix}.bam > ${sample_id}_vs_${params.input.reference_prefix}.bam.log
    """
}



/**
 * Generates expression-level transcript abundance
 *
 * depends: samtools_index
 */
process stringtie {
  // module "stringtie"
  // time params.software.stringtie.time
  tag { sample_id }

  label "multithreaded"
  label "stringtie"

  input:
    // We don't really need the .bam file, but we want to ensure
    // this process runs after the samtools_index step so we
    // require it as an input file.
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.bam") from BAM_INDEXED_FOR_STRINGTIE
    file gtf_file from GTF_FILE


  output:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") into STRINGTIE_GTF
    set val(sample_id), val(1) into STRINGTIE_DONE_SAMPLES

  script:
    """
    stringtie \
    -v \
    -p ${params.execution.threads} \
    -e \
    -o ${sample_id}_vs_${params.input.reference_prefix}.gtf \
    -G $gtf_file \
    -A ${sample_id}_vs_${params.input.reference_prefix}.ga \
    -l ${sample_id} ${sample_id}_vs_${params.input.reference_prefix}.bam
    """
}



/**
 * Generates the final FPKM file
 */
process fpkm_or_tpm {
  publishDir params.output.sample_dir, mode: 'symlink'
  tag { sample_id }

  input:
    set val(sample_id), file("${sample_id}_vs_${params.input.reference_prefix}.ga") from STRINGTIE_GTF

  output:
    file "${sample_id}_vs_${params.input.reference_prefix}.fpkm" optional true into FPKMS
    file "${sample_id}_vs_${params.input.reference_prefix}.tpm" optional true into TPM

  script:
  if( params.software.fpkm_or_tpm.fpkm == true && params.software.fpkm_or_tpm.tpm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$8}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.fpkm
    awk -F"\t" '{if (NR!=1) {print \$1, \$9}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.tpm
    """
  else if( params.software.fpkm_or_tpm.fpkm == true)
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$8}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.fpkm
    """
  else if( params.software.fpkm_or_tpm.tpm == true )
    """
    awk -F"\t" '{if (NR!=1) {print \$1, \$9}}' OFS='\t' ${sample_id}_vs_${params.input.reference_prefix}.ga > ${sample_id}_vs_${params.input.reference_prefix}.tpm
    """
  else
    error "Please choose at least one output and resume GEMmaker"
}

/**
 * PROCESSES FOR CLEANING LARGE FILES
 *
 * Nextflow doesn't allow files to be removed from the 
 * work directories that are used in Channels.  If it
 * detects a different timestamp or change in file
 * size than what was cached it will rerun the process.
 * To trick Nextflow we will truncate the file to a 
 * sparce file of size zero but masquerading as its 
 * original size, we will also reset the original modify
 * and access times.
 * 
 */

/**
 * Cleans downloaded fastq files
 */

/**
 * Cleans up trimmed fastq files. 
 */

// Merge the Trimmomatic samples with Hisat's signal that it is 
// done so that we can remove these files.  
TRHIMIX = TRIMMED_SAMPLES_2_CLEAN.mix( HISAT2_DONE_SAMPLES )
TRHIMIX
  .groupTuple(size: 2)
  .set { TRIMMED_CLEANUP_READY }

process clean_trimmed {
  input:
    // We input fastq_files as a file because we need the full path.
    set val(sample_id), val(fastq_files) from TRIMMED_CLEANUP_READY

  script:
    """
    for file in ${fastq_files}
    do
      file=`echo \$file | perl -pi -e 's/[\\[,\\]]//g'` 
      if [ ${params.publish.keep_trimmed_fastq} = false ]; then
        if [ -e \$file ]; then
          # Log some info about the file for debugging purposes
          echo "cleaning \$file"
          stat \$file
          # Get file info: size, access and modify times 
          size=`stat --printf="%s" \$file`
          atime=`stat --printf="%X" \$file`
          mtime=`stat --printf="%Y" \$file`
          # Make the file size 0 and set as a sparse file
          > \$file
          truncate -s \$size \$file
          # Reset the timestamps on the file
          touch -a -d @\$atime \$file
          touch -m -d @\$mtime \$file
        fi
      fi
    done
    """
}

/**
 * Clean up SAM files
 */

// Merge the HISAT sam file with samtools_sort signal that it is 
// done so that we can remove these files.  
HISSMIX = HISAT2_SAM_2_CLEAN.mix( SAMTOOLS_SORT_DONE_SAMPLES )
HISSMIX
  .groupTuple(size: 2)
  .set { SAM_CLEANUP_READY }

process clean_sam {
  input:
    // We input sam_files as a file because we need the full path.
    set val(sample_id), val(sam_files) from SAM_CLEANUP_READY

  script:
    """
    for file in ${sam_files}
    do
      file=`echo \$file | perl -pi -e 's/[\\[,\\]]//g'` 
      if [ -e \$file ]; then
        # Log some info about the file for debugging purposes
        echo "cleaning \$file"
        stat \$file
        # Get file info: size, access and modify times 
        size=`stat --printf="%s" \$file`
        atime=`stat --printf="%X" \$file`
        mtime=`stat --printf="%Y" \$file`
        # Make the file size 0 and set as a sparse file
        > \$file
        truncate -s \$size \$file
        # Reset the timestamps on the file
        touch -a -d @\$atime \$file
        touch -m -d @\$mtime \$file
      fi
    done
    """
}

/**
 * Clean up BAM files
 */

// Merge the samtools_sort bam file with stringtie signal that it is 
// done so that we can remove these files.  
SSSTMIX = SAMTOOLS_SORT_BAM_2_CLEAN.mix( STRINGTIE_DONE_SAMPLES )
SSSTMIX
  .groupTuple(size: 2)
  .set { BAM_CLEANUP_READY }

process clean_bam {
  input:
    // We input sam_files as a file because we need the full path.
    set val(sample_id), val(bam_files) from BAM_CLEANUP_READY

  script:
    """
    for file in ${bam_files}
    do
      file=`echo \$file | perl -pi -e 's/[\\[,\\]]//g'`
      if [ -e \$file ]; then
        # Log some info about the file for debugging purposes
        echo "cleaning \$file"
        stat \$file
        # Get file info: size, access and modify times 
        size=`stat --printf="%s" \$file`
        atime=`stat --printf="%X" \$file`
        mtime=`stat --printf="%Y" \$file`
        # Make the file size 0 and set as a sparse file
        > \$file
        truncate -s \$size \$file
        # Reset the timestamps on the file
        touch -a -d @\$atime \$file
        touch -m -d @\$mtime \$file
      fi
    done
    """
}

