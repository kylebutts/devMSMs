#' Fit outcome model
#'
#' Fits weighted marginal outcome model as a generalized linear model of the
#' user's choosing, relating exposure main effects to outcome using IPTW
#' weights.
#' @seealso [WeightIt::glm_weightit()] for more on family/link specifications.
#'
#' @param outcome name of outcome variable with ".timepoint" suffix. 
#'   See [initMSM()] for details on suffix
#' @param model character indicating one of the following outcome models:
#'  * "m0" (exposure main effects)
#'  * "m1" (exposure main effects & covariates)
#'  * "m2" (exposure main effects & their interactions)
#'  * "m3" (exposure main effects, their interactions, & covariates)
#' @param int_order integer specification of highest order exposure main effects
#'   interaction, required for interaction models ("m2", "m3")
#' @param covariates list of characters reflecting variable names of covariates,
#'   required for covariate models ("m1", "m3")
#' @param family (optional) family function specification for [WeightIt::glm_weightit()] model
#' @param link (optional) character link function specification for [WeightIt::glm_weightit()] model
#'
#' @return list containing [WeightIt::glm_weightit()] model output. It is the length 
#'  of the number of datasets (1 for a data.frame or the number of imputed datasets)
#' 
#' @examples
#' library(devMSMs)
#' data <- data.frame(
#'   ID = 1:50,
#'   A.1 = rnorm(n = 50),
#'   A.2 = rnorm(n = 50),
#'   A.3 = rnorm(n = 50),
#'   B.1 = rnorm(n = 50),
#'   B.2 = rnorm(n = 50),
#'   B.3 = rnorm(n = 50),
#'   C = rnorm(n = 50),
#'   D.3 = rnorm(n = 50)
#' )
#' obj <- initMSM(
#'   data,
#'   exposure = c("A.1", "A.2", "A.3"),
#'   ti_conf = c("C"),
#'   tv_conf = c("B.1", "B.2", "B.3", "D.3")
#' )
#' f <- createFormulas(obj, type = "short")
#' w <- createWeights(data = data, obj = obj, formulas = f)
#' 
#' fit_m0 <- fitModel(
#'   data = data, obj = obj, weights = w, 
#'   outcome = "D.3", model = "m0"
#' )
#' print(fit_m0)
#' 
#' fit_m1 <- fitModel(
#'   data = data, obj = obj, weights = w, 
#'   outcome = "D.3", model = "m1", 
#'   covariates = c("C")
#' )
#' print(fit_m1)
#' 
#' fit_m2 <- fitModel(
#'   data = data, obj = obj, weights = w, 
#'   outcome = "D.3", model = "m2", 
#'   int_order = 2
#' )
#' print(fit_m2)
#' 
#' fit_m3 <- fitModel(
#'   data = data, obj = obj, weights = w, 
#'   outcome = "D.3", model = "m3",
#'   int_order = 2, covariates = c("C")
#' )
#' print(fit_m3)
#' 
#' 
#'
#' @export
fitModel <- function(
    data, obj, weights, outcome,
    model = c("m0", "m1", "m2", "m3"), int_order = NA, covariates = NULL,
    family = NULL, link = NA,
    verbose = FALSE, save.out = FALSE) {
  ### Checks ----
  dreamerr::check_arg(verbose, "scalar logical")

	dreamerr::check_arg(save.out, "scalar logical | scalar character")

  .check_data(data)
  .check_weights(weights)
  if (!inherits(obj, "devMSM")) {
    stop("`obj` must be output from `initMSM`", call. = FALSE)
  }

  var_tab <- attr(obj, "var_tab")
  exposure <- attr(obj, "exposure")
  exposure_root <- attr(obj, "exposure_root")
  exposure_time_pts <- attr(obj, "exposure_time_pts")
  epoch <- attr(obj, "epoch")
  sep <- attr(obj, "sep")

  dreamerr::check_arg(outcome, "character scalar")
  if (inherits(data, "data.frame")) { 
    dreamerr::check_value(
      reformulate(outcome), "formula var(data)",
      .data = data, .arg_name = "outcome"
    )
  } else {
    dreamerr::check_value(
      reformulate(outcome), "formula var(data)",
      .data = data[[1]], .arg_name = "outcome"
    )
  }
  outcome_time_pt <- .extract_time_pts_from_vars(outcome, sep = sep)
  if (is.na(outcome_time_pt)) {
    stop("Please supply an outcome variable with a '.time' suffix with the outcome time point such that it matches the variable name in your data", call. = FALSE)
  }
  if (outcome_time_pt < max(exposure_time_pts)) {
    stop("Please supply an outcome variable and time point that is equal to or greater than the last exposure time point.", call. = FALSE)
  }

  if (is.null(family)) {
    family <- stats::gaussian
  }
  dreamerr::check_arg(family, "function")
  if (is.null(link) || is.na(link)) {
    link <- "identity"
  }
  dreamerr::check_arg(
    link, "scalar character",
    .message = "Please provide as a character a valid link function."
  )
  family <- family(link = link)

  model <- match.arg(model, several.ok = FALSE)
  dreamerr::check_arg(covariates, "vector character | NULL")
  dreamerr::check_arg(int_order, "scalar integer | NA")
  if (model %in% c("m2", "m3")) {
    if (is.na(int_order)) {
      stop("Please provide an integer interaction order if you select a model with interactions.", call. = FALSE)
    }
    if (int_order > length(epoch)) {
      stop("Please provide an interaction order equal to or less than the total number of epoch/time points.", call. = FALSE)
    }
  }
  if (model %in% c("m1", "m3") && is.null(covariates)) {
    stop("Please provide a list of covariates as characters if you select a covariate model.", call. = FALSE)
  }

  ## Check that covariates are not post-exposure and are in var_tab
  covars_time <- .extract_time_pts_from_vars(covariates, sep = attr(obj, "sep"))
  post_outcome_time = covars_time > outcome_time_pt
  if (any(!is.na(covars_time)) && any(post_outcome_time, na.rm = TRUE)) {
    warning(sprintf(
      "Covariates can not contain time-varying confounders measured after the outcome time point. Problematic covariates:",
      paste(na.omit(covariates[post_outcome_time]), collapse = ", ")
    ), call. = FALSE)
  }

  # getting null comparisons for LHT
  null_model <- if (model %in% c("m0", "m2")) {
    "int"
  } else {
    "covs"
  }


  ### START ----
  if (inherits(data, "mids")) {
    data_type <- "mids"
    m <- data$m
  } else if (inherits(data, "list")) {
    data_type <- "list"
    m <- length(data)
  } else {
    data_type <- "data.frame"
    data <- list(data)
    m <- 1
  }

  # fit_glm ----
  all_fits <- lapply(seq_len(m), function(k) {
    if (data_type == "mids") {
      d <- as.data.frame(mice::complete(data, k))
    } else {
      d <- data[[k]]
    }
    # `weightitMSM` object
    w <- weights[[k]]

    fit <- fit_glm(
      data = d, weights = w,
      outcome = outcome, exposure = exposure, epoch = epoch,
      model = model, int_order = int_order, covariates = covariates,
      family = family, sep = sep
    )
    return(fit)
  })
  all_fits_null <- lapply(seq_len(m), function(k) {
    if (data_type == "mids") {
      d <- as.data.frame(mice::complete(data, k))
    } else {
      d <- data[[k]]
    }
    # `weightitMSM` object
    w <- weights[[k]]

    fit_null <- fit_glm(
      data = d, weights = w,
      outcome = outcome, exposure = exposure, epoch = epoch,
      model = null_model, int_order = int_order, covariates = covariates,
      family = family, sep = sep
    )
    return(fit_null)
  })

  # Test of null ----
  if (data_type == "mids" || data_type == "list") {
    null_test <- mitml::testModels(all_fits, all_fits_null)
  } else {
    null_test <- anova(all_fits[[1]], all_fits_null[[1]])
  }

  class(all_fits) <- c("devMSM_models", "list")
  attr(all_fits, "outcome") <- outcome
  attr(all_fits, "model") <- model
  attr(all_fits, "null_test") <- null_test
  attr(all_fits, "obj") <- obj

  if (verbose) print(all_fits, i = 1)
  
  if (save.out == TRUE || is.character(save.out)) {
    home_dir <- attr(obj, "home_dir")
    out_dir <- fs::path_join(c(home_dir, "models"))
    .create_dir_if_needed(out_dir)

    if (is.character(save.out)) {
      file_name <- save.out
    } else {
      file_name <- sprintf(
        "outcome_%s-exposure_%s-model_%s.rds",
        gsub("\\.", "_", outcome), 
        exposure_root, 
        model
      )
    }

    out <- fs::path_join(c(out_dir, file_name))
    cat(sprintf(
      '\nSaving model fits to `.rds` file. To load, call:\nreadRDS("%s")\n',
      out
    ))
    saveRDS(all_fits, out)
  }

  return(all_fits)
}

#' @rdname fitModel
#'
#' @param x devMSM_models object from `fitModel`
#' @inheritParams devMSM_common_docs
#' 
#' @param ... ignored
#' @export
print.devMSM_models <- function(x, i = 1, save.out = FALSE, ...) {
  model <- attr(x, "model")
  outcome <- attr(x, "outcome")
  null_test <- attr(x, "null_test")
  obj <- attr(x, "obj")
  data_type <- attr(obj, "data_type")
  exposure_root <- attr(obj, "exposure_root")

  msg_null_test <- c(
    "Please inspect the following likelihood ratio test to determine if the exposures collective predict significant variation in the outcome compared to a model without exposure terms.",
    "\n",
    "We strongly suggest only conducting history comparisons if the likelihood ratio test is significant.",
    "\n"
  )

  if (identical(i, TRUE)) {
    if (data_type %in% c("mids", "list")) {
      lapply(seq_along(x), function(j) {
        print(x, i = j, save.out = save.out)
      })
    } else {
      i = 1
    }
  } 
  
  xi <- x[[i]]
  t <- modelsummary::modelsummary(
    xi,
    statistic = c("CI" = "[{conf.low}, {conf.high}]", "p" = "{p.value}"),
    shape = term ~ model + statistic,
    gof_map = c("nobs", "r.squared"),
    output = "tinytable"
  )
  if (data_type == "mids" || data_type == "list") {
    msg_model_sum <- sprintf(
      "\n\nThe marginal model, %s, for imputed dataset %s is summarized below:\n",
      model, i
    )
  } else {
    msg_model_sum <- sprintf(
      "\n\nThe marginal model, %s, is summarized below:\n",
      model
    )
  }
  message(msg_null_test)
  print(null_test)
  cat(msg_model_sum)
  print(t, "markdown")

  if (save.out == TRUE || is.character(save.out)) {
    home_dir <- attr(obj, "home_dir")
    out_dir <- fs::path_join(c(home_dir, "models"))
    .create_dir_if_needed(out_dir)

    if (data_type == "data.frame") {
      i_str <- ""
    } else {
      i_str <- sprintf("-imp_%s", i)
    }

    if (is.character(save.out)) {
      file_name <- save.out
    } else {
      file_name <- sprintf(
        "fit_model_summary-outcome_%s-exposure_%s-model_%s%s.txt",
        gsub("\\.", "_", outcome), 
        exposure_root, 
        model, i_str
      )
    }

    out <- fs::path_join(c(out_dir, file_name))
    cat(sprintf(
      '\nSaving model statistics table to file:\n%s\n',
      out
    ))
    if (fs::path_ext(out) == "pdf") {
      tinytable::save_tt(
        tinytable::format_tt(t, escape = TRUE),
        output = out, overwrite = TRUE
      )
    } else {
      tinytable::save_tt(t, output = out, overwrite = TRUE)
    }
  }

  return(invisible(t))
}
