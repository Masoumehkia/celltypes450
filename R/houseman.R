library(parallel)
library(nlme)

#' Perform the anti-logit
#' @param M matrix of M values on which to apply anti-logit.
#' @return beta matrix
#' @export
m.ilogit = function(M){
    res = exp(M) / (1 + exp(M))
    rownames(res) = rownames(M)
    colnames(res) = colnames(M)
    res
}

#' Perform the logit transform.
#' @param b matrix of beta values on which to apply logit.
#' @return M matrix
#' @export
m.logit = function(b){
    res = log(b) - log(1 - b)
    rownames(res) = rownames(b)
    colnames(res) = colnames(b)
    res
}

penFitOne = function(y, Zmat){
  adj = y
  is.obs = !is.na(y)
  Z = Zmat[is.obs,,drop=FALSE]
  y = y[is.obs]
  id = rep(1,length(y))
  lmod = try(lme(y~1, random=list(id=pdIdent(~Z-1))), silent=TRUE)
  if(!inherits(lmod,"try-error")){
    adj[is.obs] = resid(lmod) + lmod$coef$fixed[1]
  }# else {
  #    message(lmod)
  #}
  list(modelFit=lmod, adjusted=adj)
}

penFitAll = function(Ymat, Zmat){
  nFeature = dim(Ymat)[1]

  mu = sigma = tau = rep(NA, nFeature)
  beta = matrix(NA, nFeature, dim(Zmat)[2])
  adjusted = matrix(NA, nFeature, dim(Ymat)[2])
  nbad = 0
  for(i in 1:nFeature){
    pf = penFitOne(Ymat[i,], Zmat)

    if(inherits(pf$modelFit,"try-error")){
      nbad = nbad + 1
      mu[i] = mean(Ymat[i,],na.rm=TRUE)
      sigma[i] = var(Ymat[i,],na.rm=TRUE)
      tau[i] = 0
      beta[i,] = 0
    }
    else{
      mu[i] = pf$modelFit$coef$fixed[1]
      sigma[i] = pf$modelFit$sigma^2
      tau[i] = getVarCov(pf$modelFit)[1,1]
      beta[i,] = pf$modelFit$coef$random$id
    }
    adjusted[i,] = pf$adjusted
  }
  message(paste("total with error in model fit:", nbad))
  list(mu=mu, beta=beta, tau=tau, sigma=sigma, adjusted=adjusted)
}

#' Estimate cell-type coefficients. Returns matrix of cell-type proportions.
#'
#' @param B matrix of beta values (n_probes * n_samples) rownames must
#'        be the illumina cg id or the chrom:position
#' @param top_n number of probes from cell.coefs to use
#' @param mc.cores number of cores to use for parallelization
#' @param cell.coefs path to tab-delimited file containind DMR-probes for the
#'        cell types of interest. system.file("extdata", "houseman-dmrs.txt",
#'        package="celltypes450")
#' @return matrix of estimated cell-type proportions
#' @export
estimate.cell.proportions = function(B, top_n=500, mc.cores=2,
                              cell.coefs=NULL) {
    stopifnot(all((B > 0) & (B < 1), na.rm=TRUE))

    if(is.null(cell.coefs)){
      if(nrow(B) <= 200000){
        if(length(grep("^cg", rownames(B), value=TRUE, perl=TRUE)) >=
           length(grep("^chr", rownames(B), value=TRUE, perl=TRUE))){
          cell.coefs = system.file("extdata", "houseman-dmrs.txt", package="celltypes450")
        } else {
          cell.coefs = system.file("extdata", "houseman-dmrs-locs.txt", package="celltypes450")
        }
        warning("We suggest you use at least 2x10^5 probes")
      }
        # rownames are cg id.
        if(length(grep("^cg", rownames(B), value=TRUE, perl=TRUE)) > 200000){
            cell.coefs = system.file("extdata", "houseman-dmrs.txt", package="celltypes450")
        } else { # row names are e.g. chr17:12345
            cell.coefs = system.file("extdata", "houseman-dmrs-locs.txt", package="celltypes450")
        }
    }

    dmr.coefs = read.delim(cell.coefs, row.names=1)
    # take shared probes. may be differences if beta is from 450k
    dmr.coefs = dmr.coefs[rownames(dmr.coefs) %in% rownames(B),]
    dmr.coefs = as.matrix(dmr.coefs[1:min(top_n, nrow(dmr.coefs)),])
    stopifnot(nrow(dmr.coefs) > 0)

    # reporter matrix
    Lwbc = diag(ncol(dmr.coefs))[-(1:2),]
    Lwbc[1:2,2] = 1 ; Lwbc[,1] = 1
    rownames(Lwbc) = colnames(dmr.coefs)[-(1:2)]
    colnames(Lwbc) = colnames(dmr.coefs)
    dmrs = rownames(dmr.coefs)

    message(paste0("using ", length(dmrs), " dmrs"))

    omega.mix = projectWBC(B[dmrs,],
        dmr.coefs[dmrs,],
        contrastWBC=Lwbc,
        nonnegative=TRUE,
        lessThanOne=FALSE)

    omega.mix = (1 / apply(omega.mix, 1, sum)) * omega.mix
    return(omega.mix)
}

#' Adjust Beta for cell mixture. Returns beta of the average cell-type.
#'
#' For simply estimating the cell-type proportions, see
#' estimate.cell.proportions.
#'
#' @param B matrix of beta values (n_probes * n_samples) rownames must
#'        be the illumina cg id or the chrom:position
#' @param top_n number of probes from cell.coefs to use
#' @param mc.cores number of cores to use for parallelization
#' @param cell.coefs path to tab-delimited file containind DMR-probes for the
#'        cell types of interest. Ignored if omega.mix is provided.
#'        system.file("extdata", "houseman-dmrs.txt", package="celltypes450")
#' @param omega.mix pre-specified matrix of cell-type coefficients. If
#'        not specified, this will be estimated from the data.
#' @return matrix of adjusted beta values
#' @export
adjust.beta = function(B, top_n=500, mc.cores=2,
                       cell.coefs=NULL,
                       omega.mix=NULL){
    if (is.null(omega.mix)) {
        omega.mix <- estimate.cell.proportions(B=B, top_n=top_n, mc.cores=mc.cores, cell.coefs=cell.coefs)
    }
    stopifnot(ncol(B) == nrow(omega.mix))

    message("adjusting beta (this will take a while)...")
    tmpList = lapply(1:mc.cores, function(i){ seq(from=i, to=nrow(B), by=mc.cores) })
    tmpAdj = mclapply(tmpList, function(ix){ penFitAll(B[ix,], omega.mix) }, mc.cores=mc.cores)

    adjBeta = matrix(NA, nrow(B), ncol(B))
    for (i in 1:length(tmpList)){
        adjBeta[tmpList[[i]],] = tmpAdj[[i]]$adjusted
    }
    nCpGs = nrow(B) * ncol(B)

    # after adjusting, set values < 0 or > 1 to the smallest observed value
    epsilon.min = min(B, 1 - B)
    epsilon.max = 1 - epsilon.min

    message(sprintf("%0.3g%% of values < epsilon:", sum(adjBeta < epsilon.min, na.rm=TRUE) / nCpGs * 100))
    message(sprintf("%0.3g%% of values > 1-epsilon:", sum(adjBeta > epsilon.max, na.rm=TRUE) / nCpGs * 100))
    message("these will be changed to epsilon, 1-epsilon respectively")

    adjBeta = pmax(adjBeta, epsilon.min)
    adjBeta = pmin(adjBeta, epsilon.max)
    rownames(adjBeta) = rownames(B)
    colnames(adjBeta) = colnames(B)

    return(adjBeta)
}
