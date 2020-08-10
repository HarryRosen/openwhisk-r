#!/usr/local/bin/Rscript
library('jsonlite')
args <- commandArgs(trailingOnly = TRUE)

n <- 100
coin <- c('foo', 'bar')
flips <- sample(coin, size=n, replace=TRUE)
freq <- table(flips)
dt <- as.data.frame(freq)

cat('{"payload": ', toJSON(args), ', "response": ', toJSON(split(dt$Freq, dt$flips)), '}')
