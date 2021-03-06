#
# Implement the HDS model of Royle (2004) for the gridded distance
# observations made along IMBCR transects
#
# Author: Kyle Taylor (kyle.taylor@pljv.org) [2017]
#

#
# Todos : (2) test a standard implementation of distsamp with pooling
#         instead of gdistsamp; (3) test an implementation of station-level
#         distsamp; (4) test an implementation of gmultmix.
#

require(rgdal)
require(raster)
require(rgeos)
#require(reshape)
require(parallel)

require(OpenIMBCR)
require(unmarked)

#
# Define our workspace
#
# setwd("/global_workspace/imbcr_number_crunching/k_taylor_imbcr_hds_workflow")
# pljv_boundary <- readOGR("/gis_data/PLJV/","PLJV_Boundary", verbose=F)

#
# Define some useful local functions for manipulating IMBCR data
#
#' hidden function that greps for four-letter-codes
birdcode_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^bird")])
}
#' hidden function that greps for four-letter-codes
commonname_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^c.*.[.]n.*.")])
}
#' hidden function that greps for the distance field name
distance_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^rad")])
}
#' hidden function that greps for the transect field name
transect_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^tran")])
}
#' hidden function that greps for the timeperiod field name
timeperiod_fieldname <- function(df=NULL){
  return(names(df)[grepl(tolower(names(df)),pattern="^tim")])
}
#' kludging to back-fill any transect stations in an imbcr data.frame
#' that were sampled, but where a focal species wasn't observed, with
#' NA values
#' @export
scrub_imbcr_df <- function(df,
                           allow_duplicate_timeperiods=F,
                           four_letter_code=NULL,
                           back_fill_all_na=F,
                           drop_all_na=F){
  # throw-out any lurking 88 values, count before start values, and
  # -1 distance observations
  df <- df[!df@data[, timeperiod_fieldname(df)] == 88, ]
  df <- df[!df@data[, timeperiod_fieldname(df)] == -1, ]
  df <- df[!df@data[, distance_fieldname(df)]   == -1, ]
  # build a dataframe for our detections
  detected <- toupper(df@data[, birdcode_fieldname(df)]) ==
    toupper(four_letter_code)
  # define a pool of potential non-detections
  not_detected <- df[!detected, ]
  not_detected@data[, distance_fieldname(df)] <- NA
  not_detected@data[, birdcode_fieldname(df)] <- toupper(four_letter_code)
  not_detected@data[, commonname_fieldname(df)] <-
    as.character(df@data[which(detected == T)[1],commonname_fieldname(df)])
  not_detected@data[, 'cl_count']             <- 0 # not used, but stay honest
  # allow a single NA value for each station, but only keep the NA values
  # if we didn't observe the bird at that point -- by default, don't allow
  # duplicate NA's within a time-period
  not_detected <- not_detected[!duplicated(not_detected@data[,
                    c(transect_fieldname(not_detected), "year", "point",
                      if (allow_duplicate_timeperiods)
                        timeperiod_fieldname(not_detected)
                      else NULL
                    )
                  ]), ]
  # allow multiple detections at stations
  detected <- df[detected, ]
  # take the merge of detections and non-duplicated, non-detections as
  # our new data.frame
  transect_heuristic <- function(x=NULL){
    x <- x@data[, c(transect_fieldname(df), 'year', 'point')]
    return(round(sqrt(as.numeric(x[,1])) + sqrt(x[,2]) + sqrt(x[,3]),5))
  }
  not_detected <- not_detected[
      !transect_heuristic(not_detected) %in%
      transect_heuristic(detected),
    ]
  df <- rbind(y=detected, x=not_detected)
  # zero-inflation fix (1) : drop transects without at least one detection
  if(!back_fill_all_na){
    valid_transects <- unique(detected@data[,transect_fieldname(df)])
    df <- df[df@data[,transect_fieldname(df)] %in% valid_transects,]
  }
  # zero-inflation fix (2) : drop all NA values
  if(drop_all_na){
    df <- detected
  }
  df[order(sqrt(as.numeric(df$transectnum))+sqrt(df$year)+sqrt(df$point)),]
}
#'
#' @export
calc_transect_effort <- function(df=NULL){
  transects <- unique(as.character(df@data[,transect_fieldname(df)]))
  for(t in transects){
    for(y in unique(df@data[df@data[, transect_fieldname(df)] == t, "year"])){
      focal <- df@data[, transect_fieldname(df)] == t & df@data[, "year"] == y
      df@data[focal, 'effort'] <- length(unique(df@data[focal,'point']))
    }
  }
  return(df)
}
#'
#' @export
calc_time_of_day <- function(df=NULL){
  df$tod <- as.numeric(df$starttime)
}
#'
#' @export
calc_day_of_year <- function(df=NULL){
  if(inherits(df,"Spatial")){
     s <- df
    df <- df@data
  }
  df$doy <- as.numeric(strftime(as.POSIXct(as.Date(as.character(
    df$date), "%m/%d/%Y")),format="%j"))
  if(exists("s")){
    s@data <- df
    return(s)
  } else {
    return(df)
  }
}
#'
#' @export
calc_dist_bins <- function(df=NULL, p=0.90, breaks=10){
  if(inherits(df,"Spatial")){
     s <- df
    df <- df@data
  }
  # define our bin intervals from breaks
  if(length(breaks) == 1){
    bin_intervals <- seq(
        from=0,
        to=quantile(df[,distance_fieldname(df)], p=0.90, na.rm=T),
        length.out=breaks+1
      )
  } else {
    bin_intervals <- breaks
  }
  # build a distance class using the our calculated breaks
  df[,'dist_class'] <- 0
  for (j in length(bin_intervals):2){
    match <- which(df[, distance_fieldname(df)] <= bin_intervals[j])
    df[match, 'dist_class'] <- as.character(j-1)
  }
  # if we haven't matched but a radial distance was recorded, it
  # belongs in the furthest distance bin
  match <- df[,'dist_class'] == 0 & !is.na(df[, distance_fieldname(df)])
    df[match,'dist_class'] <- as.character(length(breaks)-1)
  # assume all remaining unmatched values are non-detections
  df[df[,'dist_class'] == 0, 'dist_class'] <- NA
  # return the breaks and the processed data.frame
  # back to user for inspection
  if(exists("s")){
    s@data <- df
    return(list(distance_breaks=bin_intervals,processed_data=s))
  } else {
    return(list(distance_breaks=bin_intervals,processed_data=df))
  }
}
#' hidden function that summarizes imbcr transect covariate data and metadata
#' by year (with list comprehension). This allows you to calculate covariates
#' at the IMBCR station level and then pool (summarize) the observations by
#' transect and year
pool_by_transect_year <- function(x=NULL, df=NULL, breaks=NULL, covs=NULL,
                                  summary_fun=median){
  breaks <- length(breaks)
  transect_year_summaries <- data.frame()
  # summarize focal_transect_year by breaking into counts within
  # distance classes and binding effort, year, and covs calculated
  # at the transect scale
  years <- sort(unique(df[df[,transect_fieldname(df)] == x, "year"]))
  for(year in years){
    focal_transect_year <- df[
      df[,transect_fieldname(df)] == x & df$year == year, ]
    # pre-allocate zeros for all bins
    distances <- rep(0,(breaks-1))
      names(distances) <- 1:(breaks-1)
    # build a pivot table of observed bins
    dist_classes <- sort(focal_transect_year$dist_class) # drop NA's
      dist_classes <- table(as.numeric(dist_classes))
    # merge pivot with pre-allocate table and add an NA bin
    distances[names(distances) %in% names(dist_classes)] <- dist_classes
      distances <- append(distances,
                          sum(is.na(focal_transect_year$dist_class)))
    distances <- as.data.frame(matrix(distances,nrow=1))
      names(distances) <- paste("distance_",c(1:(breaks-1),"NA"),sep="")
    # summarize each of the covs across the transect-year
    summary_covs <- matrix(rep(NA,length(covs)),nrow=1)
      colnames(summary_covs) <- covs
    for(cov in covs){
      # some covs are year-specific; filter accordingly
      cov_year <- names(focal_transect_year)[
          grepl(names(focal_transect_year),pattern=cov)
        ]
      if(length(cov_year)>1){
          cov_year <- cov_year[grepl(cov_year,pattern=as.character(year))]
        }
      summary_covs[,cov_year] <- summary_fun(
          focal_transect_year[,cov_year],
          na.rm=T
        )
    }
    # post-process pooled transect-year
    # keep most of our vars intact, but drop those that lack meaning at
    # the transect scale or that we have summarized above
    meta_vars <- colnames(df)[!colnames(df) %in%
              c(transect_fieldname(df), "year", "dist_class",
                distance_fieldname(df), "timeperiod", "point", "how",
                  "FID", "visual", "migrant", "cl_count", "cl_id",
                    "ptvisitzone", "ptvisiteasting", "ptvisitnorthing",
                      "rank", covs)]
    # build our summary transect-year data.frame
    focal_transect_year <- cbind(
        focal_transect_year[1, meta_vars],
        data.frame(transectnum=x, year=year),
        distances,
        summary_covs
      )
    # merge into our annual summary table
    transect_year_summaries <-
      rbind(transect_year_summaries,focal_transect_year)
  }
  return(transect_year_summaries)
}
#' accepts a formatted IMBCR data.frame and builds an unmarkedFrameGDS
#' data.frame from it
#' @export
build_unmarked_gds <- function(df=NULL,
                               numPrimary=1,
                               distance_breaks=NULL,
                               covs=NULL,
                               summary_fun=median
                               ){
  # if we have a SpatialPointsDataFrame, calculate spatial covariates
  # and tag them on to our data.frame for our summary calculations
  if(inherits(df,"Spatial")){
     s <- df
    df <- df@data
    # calculate lat/lon covariates in WGS84
    coords <- spTransform(s,"+init=epsg:4326")@coords
      colnames(coords) <- c("lon","lat")
    df <- cbind(df,coords)
      rm(coords)
    covs <- append(covs,c("lon","lat"))
  }
  # determine distance breaks / classes, if needed
  if(is.null(distance_breaks)){
    distance_breaks  = df$distance_breaks
    distance_classes = append(sort(as.numeric(unique(
                            df$processed_data$dist_class))),
                            NA
                          )
  } else {
    distance_classes = append(1:length(distance_breaks)-1, NA)
  }
  # parse our imbcr data.frame into transect-level summaries
  # with unmarked::gdistsamp comprehension
  transects <- unique(df[,transect_fieldname(df)])
  # pool our transect-level observations
  transects <- do.call(rbind,
      lapply(
          transects,
          FUN=pool_by_transect_year,
          df=df, breaks=distance_breaks,
          covs=covs
        )
    )
  # build our unmarked frame and return to user
  return(unmarked::unmarkedFrameGDS(
      # distance bins
      y=transects[,grepl(names(transects),pattern="distance_")],
      # covariates that vary at the site (transect) level
      siteCovs=transects[,!grepl(colnames(transects),pattern="distance_")],
      # not used (covariates at the site-year level)
      yearlySiteCovs=NULL,
      survey="point",
      unitsIn="m",
      dist.breaks=distance_breaks,
      numPrimary=numPrimary # should be kept at 1 (no within-season visits)
    ))
}
#
# MAIN Workflow
#

#
# Read-in and process our raw IMBCR transect data
#

witu_imbcr_observations <-
  scrub_imbcr_df(OpenIMBCR::imbcrTableToShapefile(
    list.files("..",
         pattern="imbcr_table.csv$",
         recursive=T,
         full.names=T
       )[1]
    ),
    four_letter_code="WITU",
    back_fill_all_na=F  # keep only NA values for transects with >= 1 spp det
    #back_fill_all_na=T # keep all NA values
  )

#
# Sample environmental conditions as covariates on abundance
# We are going to arbitrarily explore buffer sizes that Niemuth et al. (2017)
# used for their BBS study of grassland birds in the Great Plains. We should be
# able to do a much better job of picking-up local-scale variables than they
# did with BBS, because the station locations are much better known than
# stop-level observations in BBS they used.
#
# These scales (radii) include : 50m, 100m, 200m, 400m, 800m, 1200m, 1600m,
# 2000m, 2400m, and 3200m.
#
# The habitat variables we will test include : 1.) Year, 2.) Latitude,
# 3.) Longitude, 4.) Shortgrass prairie (composition/configuration), 5.) Mixedg
# rass prairie (composition/configuration), 6.) Tallgrass prairie (composition/
# configuration), 7.) Sagebrush shrubland composition/configuration), 8.) Ponde
# rosa/Juniper Woodland (composition/configuration), and 9.) Forest (compositio
# n/configuration)

#
# Total variables : (10 scales) * 2(composition+configuration metrics) * 9(
# plant communities) + Year + Lat + Lon = 163 variables tested step-wise, by
# scale, using AIC. That's 2^(19) = 524,288 models to test, per-scale.
#



# calculate distance bins
breaks <- append(0,as.numeric(quantile(as.numeric(
    witu_imbcr_observations$radialdistance),
    na.rm=T,
    probs=seq(0.05,0.90,length.out=9))
  ))

witu_imbcr_observations <- calc_dist_bins(
                               witu_imbcr_observations,
                               breaks=breaks
                             )[[2]]

# Build our covariates on detection, following guidance from
# Niemuth et al. (2017) and Rob Sparks at BCR. These include:
# 1.) Year, 2.) Ordinal Day of Year, 3.) Ordinal Time of Day (strike),
# 4.) Transect ID, 5.) Observer, 6.) Station Number (strike)
#
witu_imbcr_observations <- calc_day_of_year(witu_imbcr_observations)
witu_imbcr_observations <- calc_transect_effort(witu_imbcr_observations)

#
# Fit the HDS model of Royle (2004), using the implementation
# from the 'unmarked' package. We are using gdistsamp here, but
# we are not using the availability sub-model or the negative binomial
# distribution for our abundance estimates, so this really is just
# the model of Royle (2004) [distsamp].
#



# clean up the unmarked data.frame. prefer dropping the NA
# bin here (rather than in the imbcr data.frame), because here
# we still have an accurate account of effort

scrub_unmarked_dataframe <- function(x=NULL){
  row.names(x@y) <- NULL
  row.names(x@siteCovs) <- NULL
  x@y <- x@y[,!grepl(colnames(x@y), pattern="_NA")]
  x@obsToY <- matrix(x@obsToY[,1:ncol(x@y)],nrow=1)
  # normalize our site covariates
  start <- which(grepl(colnames(umdf@siteCovs),pattern="transect"))+1
  umdf@siteCovs[,start:ncol(umdf@siteCovs)] <-
    scale(umdf@siteCovs[,start:ncol(umdf@siteCovs)])
  return(x)
}

umdf <- scrub_unmarked_dataframe(build_unmarked_gds(
    df=witu_imbcr_observations,
    covs=NULL,
    distance_breaks=breaks
  ))

intercept_m <- unmarked::gdistsamp(
    ~1+offset(log(effort)), # abundance
    ~1,                     # availability
    ~1,                     # detection
    data=umdf,
    keyfun="halfnorm",
    mixture="NB",
    se=T,
    K=50,
  )

poly_space_time_m <- unmarked::gdistsamp(
    ~poly(year,2)+poly(lat,3)+poly(lon,3)+offset(log(effort)), # abundance
    ~1,                                                        # availability
    ~poly(year,2)+doy,                                         # detection
    data=umdf,
    keyfun="halfnorm",
    mixture="NB",
    se=T,
    K=50,
  )

#
# Project our model across the extent of our input raster space
# (the boundaries of the PLJV region)
#
