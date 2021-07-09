
nextflow.enable.dsl = 2

// Assess cpu and memory of current system
include { get_resources } from '../../utilities/functions'
RESOURCES = get_resources(workflow.profile, params.max_memory, params.cpus)
PROCESS_NAME = "qc_reads"

process QC_READS {
    /* Cleanup the reads using Illumina-Cleanup */
    tag "${sample}"
    label "max_cpus"
    label "qc_reads"

    publishDir "${params.outdir}/${sample}/logs", mode: "${params.publish_mode}", overwrite: params.overwrite, pattern: "${PROCESS_NAME}/*"
    publishDir "${params.outdir}/${sample}", mode: "${params.publish_mode}", overwrite: params.overwrite, pattern: "quality-control/*"
    publishDir "${params.outdir}/${sample}", mode: "${params.publish_mode}", overwrite: params.overwrite, pattern: "*error.txt"

    input:
    tuple val(sample), val(sample_type), val(single_end), path(fq), path(extra), path(genome_size)

    output:
    file "*-error.txt" optional true
    file "quality-control/*"
    tuple val(sample), val(single_end),
        path("quality-control/${sample}*.fastq.gz"),emit: READS,optional: true//,emit: COUNT_31MERS, ARIBA_ANALYSIS,MINMER_SKETCH, CALL_VARIANTS,MAPPING_QUERY optional true
    tuple val(sample), val(sample_type), val(single_end),
        path("quality-control/${sample}*.fastq.gz"), path(extra),
        path(genome_size),emit: ASSEMBLY, optional: true

    tuple val(sample), val(single_end),
        path("quality-control/${sample}*.{fastq,error-fq}.gz"),
        path(genome_size),emit: QC_FINAL_SUMMARY, optional: true
    file "${PROCESS_NAME}/*" optional true

    shell:
    qc_ram = task.memory.toString().split(' ')[0]
    is_assembly = sample_type.startsWith('assembly') ? true : false
    qin = sample_type.startsWith('assembly') ? 'qin=33' : 'qin=auto'
    adapters = params.adapters ? path(params.adapters) : 'adapters'
    phix = params.phix ? path(params.phix) : 'phix'
    '''
    LOG_DIR="!{PROCESS_NAME}"
    mkdir -p quality-control ${LOG_DIR}
    ERROR=0
    GENOME_SIZE=`head -n 1 !{genome_size}`
    MIN_BASEPAIRS=$(( !{params.min_coverage}*${GENOME_SIZE} ))
    TOTAL_BP=$(( !{params.coverage}*${GENOME_SIZE} ))

    # Print captured STDERR incase of exit
    function print_stderr {
        cat .command.err 1>&2
        ls ${LOG_DIR}/ | grep ".err" | xargs -I {} cat ${LOG_DIR}/{} 1>&2
    }
    trap print_stderr EXIT

    echo "# Timestamp" > ${LOG_DIR}/!{PROCESS_NAME}.versions
    date --iso-8601=seconds >> ${LOG_DIR}/!{PROCESS_NAME}.versions
    echo "# BBMap (bbduk.sh, reformat.sh) Version" >> ${LOG_DIR}/!{PROCESS_NAME}.versions
    bbduk.sh --version 2>&1 | grep " version" >> ${LOG_DIR}/!{PROCESS_NAME}.versions 2>&1

    # Verify AWS files were staged
    if [[ ! -L "!{fq[0]}" ]]; then
        if [ "!{single_end}" == "true" ]; then
            check-staging.py --fq1 !{fq[0]} --extra !{extra} --genome_size !{genome_size} --is_single
        else
            check-staging.py --fq1 !{fq[0]} --fq2 !{fq[1]} --extra !{extra} --genome_size !{genome_size}
        fi
    fi

    if [ "!{params.skip_qc}" == "true" ]; then
        echo "Sequence QC was skipped for !{sample}" > quality-control/!{sample}-qc-skipped.txt
        if [[ -L "!{fq[0]}" ]]; then
            if [ "!{single_end}" == "false" ]; then
                # Paired-End Reads
                ln -s `readlink !{fq[0]}` quality-control/!{sample}_R1.fastq.gz
                ln -s `readlink !{fq[1]}` quality-control/!{sample}_R2.fastq.gz
            else
                # Single-End Reads
                ln -s `readlink !{fq[0]}` quality-control/!{sample}.fastq.gz
            fi
        else
            if [ "!{single_end}" == "false" ]; then
                # Paired-End Reads
                cp !{fq[0]} quality-control/!{sample}_R1.fastq.gz
                cp !{fq[1]} quality-control/!{sample}_R2.fastq.gz
            else
                # Single-End Reads
                cp  !{fq[0]} quality-control/!{sample}.fastq.gz
            fi
        fi
    else
        if [ "!{single_end}" == "false" ]; then
            # Paired-End Reads
            # Remove Adapters
            bbduk.sh -Xmx!{qc_ram}g \
                in=!{fq[0]} in2=!{fq[1]} \
                out=adapter-r1.fq out2=adapter-r2.fq \
                ref=!{adapters} \
                k=!{params.adapter_k} \
                ktrim=!{params.ktrim} \
                mink=!{params.mink} \
                hdist=!{params.hdist} \
                tpe=!{params.tpe} \
                tbo=!{params.tbo} \
                threads=!{task.cpus} \
                ftm=!{params.ftm} \
                !{qin} ordered=t \
                stats=${LOG_DIR}/bbduk-adapter.log 1> ${LOG_DIR}/bbduk-adapter.out 2> ${LOG_DIR}/bbduk-adapter.err

            # Remove PhiX
            bbduk.sh -Xmx!{qc_ram}g \
                in=adapter-r1.fq in2=adapter-r2.fq \
                out=phix-r1.fq out2=phix-r2.fq \
                ref=!{phix} \
                k=!{params.phix_k} \
                hdist=!{params.hdist} \
                tpe=!{params.tpe} \
                tbo=!{params.tbo} \
                qtrim=!{params.qtrim} \
                trimq=!{params.trimq} \
                minlength=!{params.minlength} \
                minavgquality=!{params.maq} \
                !{qin} qout=!{params.qout} \
                tossjunk=!{params.tossjunk} \
                threads=!{task.cpus} \
                ordered=t \
                stats=${LOG_DIR}/bbduk-phix.log 1> ${LOG_DIR}/bbduk-phix.out 2> ${LOG_DIR}/bbduk-phix.err

            # Error Correction
            if [ "!{params.skip_error_correction}" == "false" ]; then
                echo "# Lighter Version" >> ${LOG_DIR}/!{PROCESS_NAME}.versions
                lighter -v >> ${LOG_DIR}/!{PROCESS_NAME}.versions 2>&1
                lighter -od . -r phix-r1.fq -r phix-r2.fq -K 31 ${GENOME_SIZE} -maxcor 1 -zlib 0 -t !{task.cpus} 1> ${LOG_DIR}/lighter.out 2> ${LOG_DIR}/lighter.err
            else
                echo "Skipping error correction"
                ln -s phix-r1.fq phix-r1.cor.fq
                ln -s phix-r2.fq phix-r2.cor.fq
            fi

            # Reduce Coverage
            if (( ${TOTAL_BP} > 0 )); then
                reformat.sh -Xmx!{qc_ram}g \
                    in=phix-r1.cor.fq in2=phix-r2.cor.fq \
                    out=subsample-r1.fq out2=subsample-r2.fq \
                    samplebasestarget=${TOTAL_BP} \
                    sampleseed=!{params.sampleseed} \
                    overwrite=t 1> ${LOG_DIR}/reformat.out 2> ${LOG_DIR}/reformat.err
            else
                echo "Skipping coverage reduction"
                ln -s phix-r1.cor.fq subsample-r1.fq
                ln -s phix-r2.cor.fq subsample-r2.fq
            fi

            # Compress
            pigz -p !{task.cpus} -c -n subsample-r1.fq > quality-control/!{sample}_R1.fastq.gz
            pigz -p !{task.cpus} -c -n subsample-r2.fq > quality-control/!{sample}_R2.fastq.gz
        else
            # Single-End Reads
            # Remove Adapters
            bbduk.sh -Xmx!{qc_ram}g \
                in=!{fq[0]} \
                out=adapter-r1.fq \
                ref=!{adapters} \
                k=!{params.adapter_k} \
                ktrim=!{params.ktrim} \
                mink=!{params.mink} \
                hdist=!{params.hdist} \
                tpe=!{params.tpe} \
                tbo=!{params.tbo} \
                threads=!{task.cpus} \
                ftm=!{params.ftm} \
                ordered=t \
                stats=${LOG_DIR}/bbduk-adapter.log 1> ${LOG_DIR}/bbduk-adapter.out 2> ${LOG_DIR}/bbduk-adapter.err

            # Remove PhiX
            bbduk.sh -Xmx!{qc_ram}g \
                in=adapter-r1.fq \
                out=phix-r1.fq \
                ref=!{phix} \
                k=!{params.phix_k} \
                hdist=!{params.hdist} \
                tpe=!{params.tpe} \
                tbo=!{params.tbo} \
                qtrim=!{params.qtrim} \
                trimq=!{params.trimq} \
                minlength=!{params.minlength} \
                minavgquality=!{params.maq} \
                qout=!{params.qout} \
                tossjunk=!{params.tossjunk} \
                threads=!{task.cpus} \
                ordered=t \
                stats=${LOG_DIR}/bbduk-phix.log 1> ${LOG_DIR}/bbduk-phix.out 2> ${LOG_DIR}/bbduk-phix.err

            # Error Correction
            if [ "!{params.skip_error_correction}" == "false" ]; then
                echo "# Lighter Version" >> ${LOG_DIR}/!{PROCESS_NAME}.versions
                lighter -v >> ${LOG_DIR}/!{PROCESS_NAME}.versions 2>&1
                lighter -od . -r phix-r1.fq -K 31 ${GENOME_SIZE} -maxcor 1 -zlib 0 -t !{task.cpus} 1> ${LOG_DIR}/lighter.out 2> ${LOG_DIR}/lighter.err
            else
                echo "Skipping error correction"
                ln -s phix-r1.fq phix-r1.cor.fq
            fi

            # Reduce Coverage
            if (( ${TOTAL_BP} > 0 )); then
                reformat.sh -Xmx!{qc_ram}g \
                    in=phix-r1.cor.fq \
                    out=subsample-r1.fq \
                    samplebasestarget=${TOTAL_BP} \
                    sampleseed=!{params.sampleseed} \
                    overwrite=t 1> ${LOG_DIR}/reformat.out 2> ${LOG_DIR}/reformat.err
            else
                echo "Skipping coverage reduction"
                ln -s phix-r1.cor.fq subsample-r1.fq
            fi

            # Compress
            pigz -p !{task.cpus} -c -n subsample-r1.fq > quality-control/!{sample}.fastq.gz
        fi

        if [ "!{params.keep_all_files}" == "false" ]; then
            # Remove intermediate FASTQ files
            rm *.fq
        fi
    fi

    echo "# FastQC Version" >> ${LOG_DIR}/!{PROCESS_NAME}.versions
    fastqc -version >> ${LOG_DIR}/!{PROCESS_NAME}.versions 2>&1

    echo "# fastq-scan Version" >> ${LOG_DIR}/!{PROCESS_NAME}.versions
    fastq-scan -v >> ${LOG_DIR}/!{PROCESS_NAME}.versions 2>&1

    # Quality stats before and after QC
    mkdir quality-control/summary/
    if [ "!{single_end}" == "false" ]; then
        # Paired-End Reads
        # fastq-scan
        gzip -cd !{fq[0]} | fastq-scan -g ${GENOME_SIZE} > quality-control/summary/!{sample}_R1-original.json
        gzip -cd !{fq[1]} | fastq-scan -g ${GENOME_SIZE} > quality-control/summary/!{sample}_R2-original.json
        gzip -cd quality-control/!{sample}_R1.fastq.gz | fastq-scan -g ${GENOME_SIZE} > quality-control/summary/!{sample}_R1-final.json
        gzip -cd quality-control/!{sample}_R2.fastq.gz | fastq-scan -g ${GENOME_SIZE} > quality-control/summary/!{sample}_R2-final.json

        # FastQC
        ln -s !{fq[0]} !{sample}_R1-original.fastq.gz
        ln -s !{fq[1]} !{sample}_R2-original.fastq.gz
        ln -s quality-control/!{sample}_R1.fastq.gz !{sample}_R1-final.fastq.gz
        ln -s quality-control/!{sample}_R2.fastq.gz !{sample}_R2-final.fastq.gz
        fastqc --noextract -f fastq -t !{task.cpus} !{sample}_R1-original.fastq.gz !{sample}_R2-original.fastq.gz !{sample}_R1-final.fastq.gz !{sample}_R2-final.fastq.gz
    else
        # Single-End Reads
        # fastq-scan
        gzip -cd !{fq[0]} | fastq-scan -g ${GENOME_SIZE} > quality-control/summary/!{sample}-original.json
        gzip -cd !{fq[0]} | fastq-scan -g ${GENOME_SIZE} > quality-control/summary/!{sample}-final.json

        # FastQC 
        ln -s !{fq[0]} !{sample}-original.fastq.gz
        ln -s quality-control/!{sample}.fastq.gz !{sample}-final.fastq.gz
        fastqc --noextract -f fastq -t !{task.cpus} !{sample}-original.fastq.gz !{sample}-final.fastq.gz
    fi
    mv *_fastqc.html *_fastqc.zip quality-control/summary/

    FINAL_BP=`gzip -cd quality-control/*.fastq.gz | fastq-scan | grep "total_bp" | sed -r 's/.*:[ ]*([0-9]+),/\1/'`
    if [ ${FINAL_BP} -lt ${MIN_BASEPAIRS} ]; then
        ERROR=1
        echo "After QC, !{sample} FASTQ(s) contain ${FINAL_BP} total basepairs. This does
                not exceed the required minimum ${MIN_BASEPAIRS} bp (!{params.min_coverage}x coverage). Further analysis 
                is discontinued." | \
        sed 's/^\\s*//' > !{sample}-low-sequence-depth-error.txt
    fi

    if [ ${FINAL_BP} -lt "!{params.min_basepairs}" ]; then
        ERROR=1
        echo "After QC, !{sample} FASTQ(s) contain ${FINAL_BP} total basepairs. This does
                not exceed the required minimum !{params.min_basepairs} bp. Further analysis
                is discontinued." | \
        sed 's/^\\s*//' > !{sample}-low-sequence-depth-error.txt
    fi

    FINAL_READS=`gzip -cd quality-control/*.gz | fastq-scan | grep "read_total" | sed -r 's/.*:[ ]*([0-9]+),/\1/'`
    if [ ${FINAL_READS} -lt "!{params.min_reads}" ]; then
        ERROR=1
        echo "After QC, !{sample} FASTQ(s) contain ${FINAL_READS} total reads. This does
                not exceed the required minimum !{params.min_reads} reads count. Further analysis
                is discontinued." | \
        sed 's/^\\s*//' > !{sample}-low-read-count-error.txt
    fi

    if [ "!{is_assembly}" == "true" ]; then
        touch quality-control/reads-simulated-from-assembly.txt
    fi

    if [ "${ERROR}" -eq "1" ]; then
        if [ "!{single_end}" == "false" ]; then
            mv quality-control/!{sample}_R1.fastq.gz quality-control/!{sample}_R1.error-fq.gz
            mv quality-control/!{sample}_R2.fastq.gz quality-control/!{sample}_R2.error-fq.gz
        else
            mv quality-control/!{sample}.fastq.gz quality-control/!{sample}.error-fq.gz
        fi
    fi

    if [ "!{params.skip_logs}" == "false" ]; then 
        cp .command.err ${LOG_DIR}/!{PROCESS_NAME}.err
        cp .command.out ${LOG_DIR}/!{PROCESS_NAME}.out
        cp .command.sh ${LOG_DIR}/!{PROCESS_NAME}.sh || :
        cp .command.trace ${LOG_DIR}/!{PROCESS_NAME}.trace || :
    else
        rm -rf ${LOG_DIR}/
    fi
    '''

    stub:
    """
    mkdir quality-control
    mkdir ${PROCESS_NAME}
    touch ${sample}-error.txt
    touch quality-control/${sample}.fastq.gz
    touch quality-control/${sample}.error-fq.gz
    touch ${PROCESS_NAME}/${sample}
    """
}


//###############
//Module testing
//###############

workflow test{

    TEST_PARAMS_CH = Channel.of([
        params.sample,
        params.sample_type,
        params.single_end,
        path(params.fq),
        path(params.extra),
        path(params.genome_size)
    ])
    qc_reads(TEST_PARAMS_CH)
}