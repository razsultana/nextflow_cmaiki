#!/usr/bin/env Rscript

library(lulu)
library(dada2)
library(seqinr)
library(ShortRead)
library(stringr)
library(ggplot2)

filterReads <- function(pairId,fwd,rev=NULL,
                        minLen=c(30,30),
                        maxEE=c(Inf,Inf),
                        truncLen=c(220,190),
                        rm.phix=TRUE,
                        truncQ=c(2,2)
                        )
{
    fwd.out <- paste(paste0(pairId,"_R1"),"trimmed.fastq",
                     sep="_")
    if ( !is.null(rev) ) {
        rev.out <- paste(paste0(pairId,"_R2"),"trimmed.fastq",sep="_")
    } else {
        truncLen <- truncLen[1]
        rev.out <- NULL
        truncQ <- truncQ[1]
        minLen <- minLen[1]
        maxEE <- maxEE[1]
    }

    # Apply dada2's filterAndTrim
    filterAndTrim(fwd, fwd.out,rev=rev, filt.rev=rev.out,
                  compress=FALSE,
                  truncLen=truncLen,
                  truncQ=truncQ,
                  minLen=minLen,
                  maxEE=maxEE)
    
    # Plot error profiles
    if ( !is.null(rev) )
    {
        fig <- plotQualityProfile(c(fwd,rev,fwd.out,rev.out))
    } else {
        fig <- plotQualityProfile(c(fwd,rev))
    }
    ggsave(paste0("qualityProfile_",pairId,".png"), plot=fig)

    # Save result
    saveRDS(readFastq(fwd.out)@id, paste0( pairId, "_R1.ids") )

    if ( !is.null(rev) )
    {
        saveRDS(readFastq(rev.out)@id, paste0( pairId, "_R2.ids") )
    }            
}

learnErrorRates <- function(fastq,pairId)
{
    errorsF <- learnErrors(fastq[1],
                           multithread=TRUE,
                           randomize=TRUE)
    saveRDS(errorsF, paste0(pairId,"_R1_errors.RDS"))
    
    if (length(fastq) > 1) {
        errorsR <- learnErrors(fastq[2],
                               multithread=TRUE,
                               randomize=TRUE)
        saveRDS(errorsR, paste0(pairId,"_R2_errors.RDS"))
    
        fig <- plotErrors(c(errorsF,errorsR), nominalQ=TRUE)
    } else {
        fig <- plotErrors(errorsF, nominalQ=TRUE)
    }
    ggsave(paste0("errorProfile_",pairId,".png"), plot=fig)
}

dadaDenoise <- function(errorFile,derepFile,pairId)
{
    errors <- readRDS(errorFile)
    derep <- derepFastq(derepFile)
    denoised <- dada(derep, err=errors, multithread=TRUE)
    # Save RDS object
    saveRDS(derep,paste0(pairId,".derep.RDS"))
    saveRDS(denoised,paste0(pairId,".dada.RDS"))
}
    
esvTable <- function(minOverlap, maxMismatch, singleEnd)
{
    sample.names <- as.character(sapply( list.files(path=".",pattern="*_R1.derep.RDS"), 
                                         function(x) unlist(strsplit(x,"_R1",fixed=T))[1] )
    )

    derepF <- lapply(list.files(path=".",pattern="*_R1.derep.RDS"),readRDS)
    denoisedF <- lapply(list.files(path=".",pattern="*_R1.dada.RDS"),readRDS)
    
    summary.derepF <- sapply(derepF, function(x) paste0(sum(x$uniques)," (",length(x$uniques)," uniques)"))
    summary.denoisedF <- sapply(denoisedF, function(x) paste0(sum(x$denoised)," (",length(x$denoised)," uniques)"))

    if (singleEnd == "false") {
        
        derepR <- lapply(list.files(path=".",pattern="*_R2.derep.RDS"),readRDS)
        denoisedR <- lapply(list.files(path=".",pattern="*_R2.dada.RDS"),readRDS)

        merged <- mergePairs( denoisedF, derepF, denoisedR, derepR,
                             minOverlap=minOverlap, maxMismatch=maxMismatch)
        saveRDS(merged,"reads_merged.RDS")
        summary.merged <- sapply(merged, function(x) paste0(sum(x$abundance)," (",length(x$abundance)," uniques)"))
        
        esvTable <- makeSequenceTable(merged)
        esv.names <- sprintf("contig%02d", 1:dim(esvTable)[2])

        uniquesToFasta(esvTable,"all.esv.fasta", ids=esv.names)

        esvTable <- cbind(esv.names, colSums(esvTable), t(esvTable) )
        colnames(esvTable) <- c("Representative_Sequence","total",sample.names)

        write.table(esvTable, file="all.esv.count_table", row.names=F, col.names=T, quote=F, sep="\t")

    } else {
        
        print("Functionality not tested yet.")
        fasta_seq <- lapply( denoisedF, function(x) names(x$denoised) )
        fasta_seq_uniq <- unique(cbind(unlist(fasta_seq)))
        esv.names <- sprintf("contig%02d", 1:length(fasta_seq_uniq)) 

        write.fasta(as.list(fasta_seq_uniq),esv.names,"all.esv.fasta")
        saveRDS(denoisedF,"reads_fwd_denoised.RDS")
        
        esvTable <- as.data.frame(lapply(denoisedF, function(x) x$denoised[fasta_seq_uniq]))

        esvTable[is.na(esvTable)] <- 0

        colnames(esvTable) <- sample.names

        esvTable <- cbind(esv.names, rowSums(esvTable), esvTable )
        colnames(esvTable) <- c("Representative_Sequence", "total", sample.names)

        summary.merged = summary.denoisedF
        
        write.table(esvTable, file="all.esv.count_table", row.names=F, col.names=T, quote=F, sep="\t")        
    }

    summary <- data.frame("Sample" = sample.names,
                          "3a-dereplication" = summary.derepF,
                          "3b-denoising" = summary.denoisedF,
                          "4-esv" = summary.merged,
                          check.names=F)
        
    write.table(summary, "count_summary.tsv", row.names=F, sep="\t")                    
}

luluCurate <- function(abundanceFile,matchListFile,threshold)
{
    otutab <- read.table(abundanceFile,
                         header=TRUE,
                         as.is=TRUE,
                         check.names=F,
                         row.names=2
                         )[-c(1,2)]
    otutab <- as.data.frame(t(otutab))
    
    matchList <- read.table(matchListFile,
                            header=FALSE,
                            as.is=TRUE,
                            col.names=c("OTU1","OTU2","pctIdentity"),                            
                            stringsAsFactors=FALSE
                            )

    if (dim(matchList)[1] > 0 & dim(otutab)[2]>1) {
        ## Run Lulu
        curated <- lulu(otutab, matchList,
                        minimum_ratio_type="min",
                        minimum_ratio=1,
                        minimum_match=97,
                        minimum_relative_cooccurence=1)
    
        write.csv(curated$curated_table,
                  paste0("lulu_table_",threshold,".csv"),
                  quote=F)
    
        write.table(curated$curated_otus,
                    paste0("lulu_ids_",threshold,".csv"),
                    quote=F,
                    row.names=F,
                    col.names=F)
    } else {
        write.csv(otutab, paste0("lulu_table_",threshold,".csv"),
                    quote=F)
        write.table(rownames(otutab),
                    paste0("lulu_ids_",threshold,".csv"),
                    quote=F,
                    row.names=F)
    }        
}
