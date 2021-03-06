version 1.0

import "HISAT2.wdl" as HISAT2
import "Picard.wdl" as Picard
import "RSEM.wdl" as RSEM
import "GroupMetricsOutputs.wdl" as GroupQCs
import "ZarrUtils.wdl" as ZarrUtils
import "SS2InputChecks.wdl" as SS2InputChecks

workflow SmartSeq2SingleCell {
  meta {
    description: "Process SmartSeq2 scRNA-Seq data, include reads alignment, QC metrics collection, and gene expression quantitication"
  }

  input {
    # version of this pipeline
    String version = "smartseq2_v3.0.0"
    # load annotation
    File genome_ref_fasta
    File rrna_intervals
    File gene_ref_flat
    # load index
    File hisat2_ref_index
    File hisat2_ref_trans_index
    File rsem_ref_index
    # ref index name
    String hisat2_ref_name
    String hisat2_ref_trans_name
    # samples
    String stranded
    String sample_name
    String output_name
    File fastq1
    File? fastq2
    Boolean paired_end
    Boolean force_no_check = false
    # whether to convert the outputs to Zarr format, by default it's set to true
    Boolean output_zarr = true
  }

  parameter_meta {
    genome_ref_fasta: "Genome reference in fasta format"
    rrna_intervals: "rRNA interval file required by Picard"
    gene_ref_flat: "Gene refflat file required by Picard"
    hisat2_ref_index: "HISAT2 reference index file in tarball"
    hisat2_ref_trans_index: "HISAT2 transcriptome index file in tarball"
    rsem_ref_index: "RSEM reference index file in tarball"
    hisat2_ref_name: "HISAT2 reference index name"
    hisat2_ref_trans_name: "HISAT2 transcriptome index file name"
    stranded: "Library strand information example values: FR RF NONE"
    sample_name: "Sample name or Cell ID"
    output_name: "Output name, can include path"
    fastq1: "R1 in paired end reads"
    fastq2: "R2 in paired end reads"
    output_zarr: "whether to run the taks that converts the outputs to Zarr format, by default it's true"
    paired_end: "Boolean flag denoting if the sample is paired end or not"
  }

  call  SS2InputChecks.checkSS2Input {
    input:
        fastq1 = fastq1,
        fastq2 = fastq2,
        paired_end = paired_end,
        force_no_check = force_no_check,
  }

  String quality_control_output_basename = output_name + "_qc"

   if( paired_end ) {
     call HISAT2.HISAT2PairedEnd {
       input:
         hisat2_ref = hisat2_ref_index,
         fastq1 = fastq1,
         fastq2 = select_first([fastq2]),
         ref_name = hisat2_ref_name,
         sample_name = sample_name,
         output_basename = quality_control_output_basename,
     }
  }
  if( !paired_end ) {
     call HISAT2.HISAT2SingleEnd {
       input:
         hisat2_ref = hisat2_ref_index,
         fastq = fastq1,
         ref_name = hisat2_ref_name,
         sample_name = sample_name,
         output_basename = quality_control_output_basename,
     }
  }

  File HISAT2_output_bam = select_first([ HISAT2PairedEnd.output_bam, HISAT2SingleEnd.output_bam] )
  File HISAT2_bam_index = select_first([ HISAT2PairedEnd.bam_index, HISAT2SingleEnd.bam_index] )
  File HISAT2_log_file = select_first([ HISAT2PairedEnd.log_file, HISAT2SingleEnd.log_file] )

  call Picard.CollectMultipleMetrics {
    input:
      aligned_bam = HISAT2_output_bam,
      genome_ref_fasta = genome_ref_fasta,
      output_basename = quality_control_output_basename,
  }

  call Picard.CollectRnaMetrics {
    input:
      aligned_bam = HISAT2_output_bam,
      ref_flat = gene_ref_flat,
      rrna_intervals = rrna_intervals,
      output_basename = quality_control_output_basename,
      stranded = stranded,
  }

  call Picard.CollectDuplicationMetrics {
    input:
      aligned_bam = HISAT2_output_bam,
      output_basename = quality_control_output_basename,
  }

  String data_output_basename = output_name + "_rsem"

  if( paired_end ) {
      call HISAT2.HISAT2RSEM as HISAT2Transcriptome {
        input:
          hisat2_ref = hisat2_ref_trans_index,
          fastq1 = fastq1,
          fastq2 = fastq2,
          ref_name = hisat2_ref_trans_name,
          sample_name = sample_name,
          output_basename = data_output_basename,
      }
  }

  if( !paired_end ) {
      call HISAT2.HISAT2RSEMSingleEnd as HISAT2SingleEndTranscriptome {
        input:
          hisat2_ref = hisat2_ref_trans_index,
          fastq = fastq1,
          ref_name = hisat2_ref_trans_name,
          sample_name = sample_name,
          output_basename = data_output_basename,
      }
  }

  File HISAT2RSEM_output_bam = select_first([ HISAT2Transcriptome.output_bam, HISAT2SingleEndTranscriptome.output_bam] )
  File HISAT2RSEM_log_file = select_first([ HISAT2Transcriptome.log_file, HISAT2SingleEndTranscriptome.log_file] )

  call RSEM.RSEMExpression {
    input:
      trans_aligned_bam = HISAT2RSEM_output_bam,
      rsem_genome = rsem_ref_index,
      output_basename = data_output_basename,
      is_paired = paired_end
  }

  Array[File] picard_row_outputs = [CollectMultipleMetrics.alignment_summary_metrics,CollectDuplicationMetrics.dedup_metrics,CollectRnaMetrics.rna_metrics,CollectMultipleMetrics.gc_bias_summary_metrics]

  # This output only exists for PE and select_first fails if array is empty
  if ( length(CollectMultipleMetrics.insert_size_metrics) > 0 ) {
    File? picard_row_optional_outputs = select_first(CollectMultipleMetrics.insert_size_metrics)
  }

  Array[File] picard_table_outputs = [
    CollectMultipleMetrics.base_call_dist_metrics,
    CollectMultipleMetrics.gc_bias_detail_metrics,
    CollectMultipleMetrics.pre_adapter_details_metrics,
    CollectMultipleMetrics.pre_adapter_summary_metrics,
    CollectMultipleMetrics.bait_bias_detail_metrics,
    CollectMultipleMetrics.error_summary_metrics,
  ]

  call GroupQCs.GroupQCOutputs {
   input:
      picard_row_outputs = picard_row_outputs,
      picard_row_optional_outputs = select_all(CollectMultipleMetrics.insert_size_metrics),
      picard_table_outputs = picard_table_outputs,
      hisat2_stats = HISAT2_log_file,
      hisat2_trans_stats = HISAT2RSEM_log_file,
      rsem_stats = RSEMExpression.rsem_cnt,
      output_name = output_name
  }

  if (output_zarr) {
    call ZarrUtils.SmartSeq2ZarrConversion {
      input:
        rsem_gene_results = RSEMExpression.rsem_gene,
        smartseq_qc_files = GroupQCOutputs.group_files,
        sample_name=sample_name
    }
  }

  output {
    # version of this pipeline
    String pipeline_version = version
    # quality control outputs
    File aligned_bam = HISAT2_output_bam
    File bam_index = HISAT2_bam_index
    File? insert_size_metrics =  picard_row_optional_outputs
    File quality_distribution_metrics = CollectMultipleMetrics.quality_distribution_metrics
    File quality_by_cycle_metrics = CollectMultipleMetrics.quality_by_cycle_metrics
    File bait_bias_summary_metrics = CollectMultipleMetrics.bait_bias_summary_metrics
    File rna_metrics = CollectRnaMetrics.rna_metrics
    Array[File] group_results = GroupQCOutputs.group_files
    # data outputs
    File aligned_transcriptome_bam = HISAT2RSEM_output_bam
    File rsem_gene_results = RSEMExpression.rsem_gene
    File rsem_isoform_results = RSEMExpression.rsem_isoform

    # zarr
    Array[File]? zarr_output_files = SmartSeq2ZarrConversion.zarr_output_files
  }
}
