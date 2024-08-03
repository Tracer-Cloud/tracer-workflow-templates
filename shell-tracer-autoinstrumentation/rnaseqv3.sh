#!/bin/bash

# FASTQC - QC layer 1
cd /workspace/tracer-workflow-templates/data

# Creating a human genome index using bowtie2 - BOWTIE2-INDEX
bowtie2-build human.fa human_index;

# Align RNA-Seq reads of control to the genome using bowtie2 - BOWTIE2-CONTROL-MAP
bowtie2 --local -x human_index -1 control1_1.fq -2 control1_2.fq -S control.sam;

# Align RNA-Seq reads of test experiment to the genome using bowtie2 - BOWTIE2-TEST-MAP
bowtie2 --local -x human_index -1 test1_1.fq -2 test1_2.fq -S test.sam;

# Convert SAM files into transcriptome FASTA files - SAM2FASTA
samtools fasta control.sam > control.fa
samtools fasta test.sam > test.fa

# Sort and Index the output sam files - SAMTOOLS-CONTROL
samtools view -@ 4 -b control.sam > control.bam 
samtools sort control.bam -@ 4 -o control.sorted.bam;
samtools index control.sorted.bam;

# Sort and Index the output sam files - SAMTOOLS-TEST
samtools view -@ 4 -b test.sam > test.bam 
samtools sort test.bam -@ 4 -o test.sorted.bam;
samtools index test.sorted.bam;

# Predict potential transcripts in control and test BAM files using StringTie - STRINGTIE
stringtie -o control.gtf -G hg19_anno.gtf control.sorted.bam;
stringtie -o test.gtf -G hg19_anno.gtf test.sorted.bam;

# Calculate transcript counts from BAM files using featureCounts - FEATURECOUNTS
featureCounts -p --countReadPairs -B -C -T 4 -a hg19_anno.gtf -o control_counts.txt control.sorted.bam;
featureCounts -p --countReadPairs -B -C -T 4 -a hg19_anno.gtf -o test_counts.txt test.sorted.bam;

# Collate logs and perform post-mapping QC with MULTIQC - MULTIQC
multiqc .;

# Summary of BAM files using deeptools - BAMSUMMARY
multiBamSummary bins --bamfiles control.sorted.bam test.sorted.bam -o rnaseq.npz; 

# PCA analysis for RNASEQ experiments - PCA
plotPCA -in rnaseq.npz -o PCA_rnaseq.png;

# RNASEQ data comparison via Fingerprint plots - FINGERPRINT
plotFingerprint -b control.sorted.bam test.sorted.bam --labels Control Test --plotFile fingerprint_rnaseq.png;

# Obtain bigwig files for visualization of data - BAMCOMPARE
bamCompare -b1 test.sorted.bam -b2 control.sorted.bam -o differential.bw -of bigwig

# Run the R script for edgeR analysis and heatmap creation
Rscript - <<EOF
# Load necessary libraries
if (!requireNamespace("edgeR", quietly = TRUE)) {
  install.packages("edgeR", repos='http://cran.rstudio.com/')
}

if (!requireNamespace("ggplot2", quietly = TRUE)) {
  install.packages("ggplot2", repos='http://cran.rstudio.com/')
}

if (!requireNamespace("reshape2", quietly = TRUE)) {
  install.packages("reshape2", repos='http://cran.rstudio.com/')
}

library(edgeR)
library(ggplot2)
library(reshape2)

# Set working directory to where the count files are
setwd("/workspace/tracer-workflow-templates/data")

# List all count files
files <- list.files(pattern = "*_counts.txt$", full.names = TRUE)

# Check if files are loaded correctly
print("Count files found:")
print(files)

# Define sample names based on the number of count files detected
sampleNames <- c("control", "test")

# Read count data into edgeR format
countData <- lapply(files, function(x) {
  data <- read.table(x, header = TRUE, row.names = 1, sep = "\t")  # Ensure correct delimiter
  counts <- data[, ncol(data)]  # Take the count column
  names(counts) <- rownames(data)
  return(counts)
})

# Combine into a single matrix
countMatrix <- do.call(cbind, countData)
print("Count matrix dimensions:")
print(dim(countMatrix))

# Verify consistency of row names across all files
consistent_rows <- Reduce(intersect, lapply(countData, names))
print("Number of consistent rows (genes) across samples:")
print(length(consistent_rows))

# Ensure the count matrix is constructed using consistent row names
countMatrix <- countMatrix[consistent_rows, , drop=FALSE]

# Visualize distribution of counts to understand data before filtering
boxplot(countMatrix, main = "Boxplot of raw counts", las = 2)

# Define group for each sample
group <- factor(sampleNames)

# Create a DGEList
dge <- DGEList(counts = countMatrix, group = group)

# Check the DGEList object
print("DGEList object:")
print(dge)

# Explore filtering threshold for low counts
# Print number of genes before filtering
print(paste("Number of genes before filtering:", nrow(dge$counts)))

# Filter lowly expressed genes with a less stringent threshold
keep <- rowSums(cpm(dge) > 0.5) >= 1  # At least 1 sample should have CPM > 0.5
dge <- dge[keep, , keep.lib.sizes=FALSE]

# Check dimensions after filtering
print("Dimensions after filtering:")
print(dim(dge$counts))

# Normalize the data
dge <- calcNormFactors(dge)

# Manually set the common dispersion for data without replicates
common_dispersion <- 0.1  # You can adjust this value based on prior knowledge or literature
dge$common.dispersion <- common_dispersion

# Perform exact test using the manually set common dispersion
et <- exactTest(dge, dispersion = common_dispersion)

# Obtain results
res <- topTags(et, n = Inf)$table

# Print summary of results
print(summary(decideTests(et)))

# Save the results to a CSV file
write.csv(res, file = "edger_results.csv")

# Create a random matrix for the heatmap
# Simulating log fold changes for 5 random genes and 2 samples (control and test)
set.seed(123)  # For reproducibility

# Generate 5 random gene names
randomGenes <- paste0("Gene_", 1:5)

# Create a 5x2 matrix of random logFC values
logCounts <- matrix(runif(5 * 2, -2, 2), nrow = 5, dimnames = list(randomGenes, c("control", "test")))

# Convert the random log-transformed data to a data frame
heatmapData <- as.data.frame(logCounts)
heatmapData$Gene <- rownames(heatmapData)

# Reshape data to long format for ggplot2
meltedHeatmapData <- melt(heatmapData, id.vars = "Gene")

# Ensure meltedHeatmapData has the correct column names
colnames(meltedHeatmapData) <- c("Gene", "Sample", "Expression")

# Plot heatmap using ggplot2
ggplot(meltedHeatmapData, aes(x = Sample, y = Gene, fill = Expression)) +
  geom_tile() +
  scale_fill_gradient2(low = "blue", high = "red", mid = "white", midpoint = 0) +
  theme_minimal() +
  labs(title = "Randomly Simulated Heatmap", x = "Sample", y = "Gene") +
  theme(axis.text.y = element_text(size = 8)) +
  theme(axis.text.x = element_text(angle = 45, hjust = 1))

# Save the plot
ggsave("heatmap_random_genes.png", width = 10, height = 8)

EOF

echo "Analysis completed. edgeR results and heatmap saved."