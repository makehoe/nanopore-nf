#!/usr/bin/env nextflow

params.read_dir='reads'
params.basecalled = ''
params.diamond = false
params.seqid=''

params.min_len_contig='100'
params.evalue='0.1'
params.outsuffix='results_'


read_ch =     params.basecalled ? Channel.empty() : Channel.fromPath( params.read_dir ).map{ it -> [ it.parent, it.name, it ] }
basefile_ch = params.basecalled ? Channel.fromPath( params.basecalled ).map{ it -> [ it.parent, it.name, it ] } : Channel.empty()


process basecall {
tag "${dir}/${name}"
publishDir "${dir}/${params.outsuffix}${name}", mode: 'copy'
stageInMode 'symlink'

input:
set val(dir), val(name), file('read_dir') from read_ch

output:
set val(dir), val(name), file('params.outsuffix') into base_ch

script:
"""
guppy_basecaller \
    -i read_dir -s . \
    --recursive \
    --records_per_fastq 0 \
    -c dna_r9.4.1_450bps_hac.cfg \
    --qscore_filtering --min_score 7 \
    --num_callers 1 --cpu_threads_per_caller ${task.cpus}

ln -s pass/fastq_runid_*.fastq Basecalled.fastq
"""
}


process demultiplex_trim {
tag "${dir}/${name}"
publishDir "${dir}/${params.outsuffix}${name}", mode: 'copy'
stageInMode ( ( params.basecalled && workflow.profile == 'zeus' ) ? 'copy' : 'symlink' )

input:
set val(dir), val(name), file('Basecalled.fastq') from base_ch.mix(basefile_ch)

output:
 set val(dir), val(name), file('barcode??.fastq') into trimmedtmp_ch

script:
"""
qcat \
  -f Basecalled.fastq -b .  \
  --trim -t ${task.cpus}
"""
}


trimmedtmp_ch
.transpose()
.filter{ dir, val, file -> file.size() > 1.MB  }
.map { dir, val, file -> tuple(dir,val, file.name[7..8], file) }
.into{trimmed_ch;trimmed2_ch}


process assemble{
tag "${dir}/${name}/${bcID}"
publishDir "${dir}/${params.outsuffix}${name}/${bcID}", mode: 'copy'

input:
set val(dir), val(name), val(bcID), file('demult.fastq') from trimmed_ch

output:
set file('Denovo_subset.fa'), val(dir), val(name), val(bcID) into denovo_ch,denovo2_ch

script:
"""


mini_assemble \
  -i  demult.fastq -p denovo -o denovo \
  -c -t ${task.cpus}

##cp denovo/denovo_final.fa Denovo_subset.fa

awk -v min_len_contig=${params.min_len_contig} \
 '{ if( substr(\$1,1,1) == ">" ){ skip=0 ; s=gensub(/LN:i:/,"",1,\$2) ; if( (s-0) < min_len_contig ){ skip=1 }} ; if( skip == 0 ){print} }' \
 denovo/denovo_final.fa >Denovo_subset.fa
"""
}

return


process blast {
tag "${dir}/${name}"
publishDir "${dir}/${params.outsuffix}${name}", mode: 'copy'

input:
set file('Denovo_subset.fa'), dir, name, bcID from denovo_ch

output:
set file('blast.tsv'), dir, name into blast_ch
set file('blast.xml'), dir, name into blast_xml_ch

when:
!params.diamond

script:
"""
blastn \
  -query Denovo_subset.fa -db ${params.blast_db} \
  -outfmt 11 -out blast.asn \
  -evalue ${params.evalue} \
  -num_threads ${task.cpus}

blast_formatter \
  -archive blast.asn \
  -outfmt 5 -out blast.xml

blast_formatter \
  -archive blast.asn \
  -outfmt "6 qaccver saccver pident length evalue bitscore stitle" -out blast_unsort.tsv

sort -n -r -k 6 blast_unsort.tsv >blast.tsv
"""
}


process diamond {
tag "${dir}/${name}"
publishDir "${dir}/${params.outsuffix}${name}", mode: 'copy'

input:
set file('Denovo_subset.fa'), dir, name from denovo2_ch

output:
set file('diamond.tsv'), dir, name into diamond_ch
set file('diamond.xml'), dir, name into diamond_xml_ch

when:
params.diamond

script:
"""
diamond blastx \
  -q Denovo_subset.fa -d ${params.diamond_db} \
  -f 5 -o diamond.xml \
  --evalue ${params.evalue} \
  -p ${task.cpus}

diamond blastx \
  -q Denovo_subset.fa -d ${params.diamond_db} \
  -f 6 qseqid  sseqid  pident length evalue bitscore stitle -o diamond_unsort.tsv \
  --evalue ${params.evalue} \
  -p ${task.cpus}

sort -n -r -k 6 diamond_unsort.tsv >diamond.tsv
"""
}


seqid_list = params.seqid?.tokenize(',')
seqid_ch = seqid_list ? Channel.from( seqid_list ) : Channel.empty()


process seqfile {
tag "${seqid}"
publishDir '.', mode: 'copy', saveAs: { filename -> "Refseq_${seqid}.fasta" }

input:
val seqid from seqid_ch

output:
set file('Refseq.fasta'), seqid into seq_ch

script:
"""
blastdbcmd \
    -db ${params.blast_db} -entry ${seqid} \
    -line_length 60 \
    -out Refseq.fasta

sed -i '/^>/ s/ .*//g' Refseq.fasta
"""
}


process align {
tag "${dir}/${name}_${seqid}"
publishDir "${dir}/${params.outsuffix}${name}", mode: 'copy', saveAs: { filename -> "Aligned_${seqid}.bam" }

input:
set file('trimmed.fastq'), dir, name, file('Refseq.fasta'), seqid from trimmed2_ch.combine( seq_ch )

output:
file('Aligned.bam') into align_ch

script:
"""
mini_align \
  -i trimmed.fastq -r Refseq.fasta \
  -p Aligned \
  -t ${task.cpus}
"""
}
