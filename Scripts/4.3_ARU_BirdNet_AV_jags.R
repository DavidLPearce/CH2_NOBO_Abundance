# Author: David L. Pearce
# Description:
#             TBD

# This code extends code from the following sources: 
#     1. Chambert, T., Waddle, J. H., Miller, D. A., Walls, S. C., 
#           and Nichols, J. D. (2018b). A new framework for analysing 
#           automated acoustic species detection data: Occupancy estimation 
#           and optimization of recordings post-processing. 
#           Methods in Ecology and Evolution, 9(3):560–570.
#     2. Kery, M. and Royle, J. A. (2020). Applied hierarchical modeling 
#           in ecology: Analysis of distribution, abundance, and species 
#           richness in R and BUGS: Volume 2: Dynamic and advanced models. 
#           Academic Press.
#     3. Doser, J. W., A. O. Finley, A. S. Weed, and E. F. Zipkin. 2021. 
#           Integrating automated acoustic vocalization data and point count 
#           surveys for estimation of bird abundance. 
#           Methods in Ecology and Evolution 12:1040–1049.

# Citation: 
#      TBD

# -------------------------------------------------------
#
#                    Load libraries
#
# -------------------------------------------------------

# Install packages (if needed)
# install.packages("tidyverse")
# install.packages("jagsUI")
# install.packages("coda")
# install.packages("mcmcplots")
# install.packages("loo")

# Load library
library(tidyverse)
library(plotly)
library(jagsUI)
library(coda)
library(mcmcplots)
library(loo)

# Set seed, scientific notation options, and working directory
set.seed(123)
options(scipen = 9999)
setwd(".")

# Setting up cores
Ncores <- parallel::detectCores()
print(Ncores) # Number of available cores
workers <- Ncores * 0.5 # For low background use 80%, for medium use 50% of Ncores
print(workers)

# Source custom function for checking Rhat values > 1.1
source("./Scripts/Rhat_check_function.R")

# Model name object
model_name <- "AV Bnet"

# -------------------------------------------------------
#
#             Variable and Object Definitions
#
# -------------------------------------------------------

# beta0 = abundance intercept 
# beta.1 = abundance trend estimate
# alpha0 = prob (on logit scale) of detecting at least one vocalization at a site
#           that is not occupied.
# alpha1 = additional prob (on logit scale) of detecting at least one vocalization at 
#           a site that is not occupied. 
# omega = mean # of false positive acoustic detections
# p = detection probability of an individual in point count data
# tau.day = precision for random day effect on true vocalization detection rate. 
# a.phi = overdispersion parameter for zero-truncated negative binomial. 
# gamma.1 = random day effect on true vocalization detection rate
# N = latent abundance process
# tp = true positive rate
# p.a = prob of detecting at least one vocalization in an acoustic recording
# v = acoustic vocalization data from clustering algorithm
# y = binary summary of v, takes value 0 if v = 0 and value 1 if v > 0. 
# c = point count data
# R = number of total sites
# J = number of repeat visits for acoustic data at each site
# J.A = max number of repeat visits at each acoustic data site. 
# n.count = number of repeat visits for count data
# R.val = number of sites where validation of acoustic data occurred
# A.times = indexing variable used to determine specific indexes with v > 0.
# K = true number of acosutic vocalizations
# k = true number of manually validated acoustic vocalizations
# n = total number of manually validated acoustic vocalizations 
# sites.a = specific indices of sites where acoustic data were obtained
# R.val = number of validated sites for acoustic data
# Other variables not defined are for computation of Bayesian p-values. 

# -------------------------------------------------------
#
#                    Load Data
#
# -------------------------------------------------------

# BirdNet detections
bnet_dat_all <- read.csv("./Data/Acoustic_Data/NOBO_BirdNETall_2024.csv")

# ARU weather covariates
weather_dat <- read.csv("./Data/Acoustic_Data/ARU_weathercovs.csv")

# Site covariates
site_covs <- read.csv("./Data/Acoustic_Data/ARU_siteCovs.csv")


# -------------------------------------------------------
#
#    Data Wrangling
#
# -------------------------------------------------------


# Subset to 14 days starting at May 26 and ending on July 17. Dates are every 4 days.
date_order <- c("2024-05-26", "2024-05-30", "2024-06-03", "2024-06-07", # in ascending order
                "2024-06-11", "2024-06-15", "2024-06-19", "2024-06-23",
                "2024-06-27", "2024-07-01", "2024-07-05", "2024-07-09",
                "2024-07-13", "2024-07-17")

# Dates and their corresponding occasion numbers
bnet_dat <- bnet_dat_all %>% filter(Date %in% date_order)
head(bnet_dat)
nrow(bnet_dat)

# Adding occasion column
bnet_dat <- bnet_dat %>%
  mutate(Occasion = match(Date, date_order))

# Adding a row count
bnet_dat$Count <- 1


# Initialize the matrix
v <- matrix(0, nrow = 27, ncol = 14)        

# Extract count data
for (i in 1:nrow(bnet_dat)) {
  
  # Extracting plot ID
  site <- bnet_dat$Site_Number[i]
  
  # Extracting Occasion
  occasion <- bnet_dat$Occasion[i]
  
  # Fill in the matrix with the number of individuals
  v[site, occasion] =  v[site, occasion] + bnet_dat$Count[i]
  
} # end loop 

# take a look
print(v)

# Renaming columns to date Month_day
formatted_dates <- format(as.Date(date_order), "%b_%d")
colnames(v) <- formatted_dates
print(v) 

# Adding rownames
rownames(v) <- as.numeric(1:27)

# Get the site numbers with at least one call
v_mat <- as.matrix(v)
sites.a <- which(rowSums(!is.na(v_mat) & v >= 1) > 0)
print(sites.a)



# Creating a binary detection matrix, values >= 1 become 1, and 0 stays 0
v_df <- as.data.frame(v)
y <- v_df %>% mutate(across(where(is.numeric), ~ if_else(. >= 1, 1, 0)))
y <- as.matrix(y)
rownames(y) <- NULL  
colnames(y) <- NULL 
print(y)

# Total number of sites
S <- as.integer(27) 

# Number of repeat visits for each site
J <- rep(14, S)  

# J.r contains the number of surveys at each acoustic site that contains at least 1 detected vocalization. 
J.r <- apply(v_mat, 1, function(a) {sum(a != 0)})
J.r <- ifelse(is.na(J.r), 0, J.r)
J.r <- as.numeric(J.r)
print(J.r)

# A.times is a R x J matrix that contains the indices of the
# specific surveys at each acoustic site that have at least one detected
# vocalization. This determines the specific components of v[i, j] that
# are used in the zero-truncated Poisson.
A.times <- matrix(NA, S, max(J))
tmp <- apply(v, 1, function(a) {which(a != 0)})
for (i in 1:S) {
  if (length(tmp[[i]]) > 0) {
    A.times[i, 1:length(tmp[[i]])] <- tmp[[i]]
  }
}
print(A.times)

# ---------------------------------------
# Manually validated  
# ---------------------------------------


# Validated Calls
# Do not include sites with no calls 
# only include occasions where at least 1 call was validated for a site
n <- read.csv("./Data/Acoustic_Data/Bnet14day_n.csv", row.names = 1)
n <- as.matrix(n)

# True Calls
# Calls found to be true, same dimension as n
k <- read.csv("./Data/Acoustic_Data/Bnet14day_k.csv", row.names = 1)
k <- as.matrix(k)

# Survey days calls were validated, same dimension as n
val.times <- read.csv("./Data/Acoustic_Data/Bnet14day_val.times.csv", row.names = 1)
val.times <- as.matrix(val.times)

# Total number of sites with manually validated data
S.val <- nrow(n)

# How many surveys were validate
J.val <- rep(14, S.val)  
 

# Check
dim(n) # dimensions
dim(k)
dim(val.times)



# ---------------------------------------
# Covariates 
# ---------------------------------------


# Format X.abund
X.abund <- as.matrix(site_covs[,-c(1:2)]) # Remove X and site id
print(X.abund)


## Extract and scale detection covariates to matrix ## 
temp_mat <- scale(weather_dat$Temp_degF)
wind_mat <- scale(weather_dat$Wind_mph)
X.det <- as.matrix(data.frame(temp = temp_mat, wind = wind_mat))
                   
# sky_vec <- as.factor(weather_dat$Sky_Condition)  # Convert to factor
# sky_dum <- model.matrix(~ sky_vec - 1)  # Create dummy variables for sky, without intercept

# Survey area in acres
area <- pi*(200^2)/4046.86

# Survey area in kilometers, for convergence

# ---------------------------------------
# Bayesian P-value
# ---------------------------------------

S.A <- sum(J.r > 0)
sites.a.v <- which(J.r > 0)
J.A <- max(J)


# ---------------------------------------
# Bundle Data 
# ---------------------------------------

Bnet14.data <- list(S = S, 
                    J = J, 
                    v = v, 
                    y = y,
                    n = n,
                    k = k, 
                    val.times = val.times, 
                    sites.a = sites.a, 
                    S.val = S.val, 
                    J.val = J.val, 
                    J.r = J.r, 
                    A.times = A.times, 
                    S.A = S.A, 
                    J.A = J.A, 
                    sites.a.v = sites.a.v, 
                    n.days = max(J),
                    X.abund = X.abund,
                    X.det = X.det,
                    Offset = area)

# Check structure
str(Bnet14.data)


# ---------------------------------------------------------- 
# 
#           Acoustic HM with Validated Calls
# 
# ----------------------------------------------------------


# -------------------
# MCMC Specifications
# -------------------
n.iter = 400000
n.burnin = 60000
n.chains = 3 
n.thin = 10
n.adapt = 5000

# Rough idea posterior samples
est_post_samps = (((n.iter - n.burnin) / n.thin) * n.chains)
print(est_post_samps)


# ----------------------------------------------------------
#                   Model 1 
# Cue Rate =  Ran eff of survey/day
# Detection = Veg Density
# Abundance = Herb Prp
# ----------------------------------------------------------

# -------------------------------------------------------
# Model Specifications
# -------------------------------------------------------

# Parameters monitored
params <- c('lambda', # Abundance
            'N_tot',
            'N',
            'beta0',
            'beta1',
            'beta2',
            'beta3',
            'Sraneff',
            'mu_s',
            'tau_s',
            'sigma_s',
            'alpha0', # Detection 
            'alpha1', 
            'alpha2',
            'gamma0', #  Vocalization
            'kappa1', 
            'kappa2',
            'Jraneff',
            'tau_j',
            'sigma_j',
            'omega',
            'delta',
            'bp.y', # Bayes p-value
            'bp.v')



# Initial Values 
inits <- function() {
  list(
    N = rep(1, S), # Abundance
    beta0 = rnorm(1, 0, 1),
    beta1 = 0,
    beta2 = 0,
    beta3 = 0,
    tau_s = 5,
    alpha0 = 0, # Detection
    alpha1 = 0, 
    alpha2 = 0,
    gamma0 = log(8),
    kappa1 = 0.6, # Vocalization
    kappa2 = -0.06, 
    omega = runif(1, 0, 10),
    tau_j = 2
  )
}#end inits

  

# -------------------------------------------------------
# Model Statement
# -------------------------------------------------------
cat(" model {
  
  # ----------------------
  # Abundance Priors
  # ----------------------
  
  # Intercept
  beta0 ~ dnorm(0, 10)
  
  # Covariate effect
  beta1 ~ dnorm(0, 10)
  beta2 ~ dnorm(0, 10)
  beta3 ~ dnorm(0, 10)


  # ------------------------
  # Detection Priors
  # ------------------------
  
  # Intercept
  alpha0 ~ dnorm(0, 10)
  
  # True individuals
  alpha1 ~ dunif(0, 500) # Constrained to be positive
  
  # Covariate effect
  alpha2 ~ dnorm(0, 1)
  
  # ------------------------
  # Call Rate Priors
  # ------------------------
  
  # False positive rate
  omega ~ dunif(0, 1000)
  
  # Calls in 30 mins by 1 individual, which is 8 +/- 4
  gamma0 ~ dnorm(log(8), 1/2)
  
  # Conspecific density effects
  kappa1 ~ dnorm(2, 1) T(0, 1) # mean of 0.6, sd of 0.4 i.e., (1/1^2); constrained between 0 and 1
  kappa2 ~ dnorm(-0.06, 625) T(-1, 0) # mean of 0.06, sd of 0.04 i.e., (1/0.04^2); constrained between -1 and 0

  # Survey random effect
  tau_j ~ dgamma(5, 5) # variance
  sigma_j <- sqrt(1 / tau_j) # standard deviation  
  for (j in 1:n.days) {
    Jraneff[j] ~ dnorm(0, sigma_j) 
  }

  # -------------------------------------------
  #
  # Likelihood and Process Model 
  #
  # -------------------------------------------
  
  # Site
  for (s in 1:S) {
    
    # ---------------------------------
    # Abundance Submodel  
    # ---------------------------------
    log(lambda[s]) <- beta0 + beta1 * X.abund[s, 7] + beta2 * X.abund[s, 18] + beta3 * X.abund[s, 7] * X.abund[s, 18]
    N[s] ~ dpois(lambda[s] * Offset)
    
    # Survey
    for (j in 1:J[s]) {
  
    # ---------------------------------
    # Detection Submodel  
    # ---------------------------------
    logit(p.a[s, j]) <- alpha0 + alpha1*N[s] + alpha2 * X.abund[s,21]  

    # ---------------------------------
    # Call rate Submodel  
    # ---------------------------------
    
    # delta[s, j] <- exp(gamma0 + Jraneff[j]) + (kappa1*N[s] + kappa2*N[s]^2)
    delta[s, j] <- max(0, exp(gamma0 + Jraneff[j]) )  #  + (kappa1 * N[s]) + (kappa2 * (N[s])^2))

    # ---------------------------------
    # Observations
    # ---------------------------------
    y[s, j] ~ dbin(p.a[s, j], 1)

    # ---------------------------------
    # True Positives 
    # ---------------------------------
    tp[s, j] <- delta[s, j] * N[s] / (delta[s, j] * N[s] + omega)

    # ---------------------------------
    # Posterior Predictive Checks  
    # ---------------------------------
    y.pred[s, j] ~ dbin(p.a[s, j], 1)
    resid.y[s, j] <- pow(pow(y[s, j], 0.5) - pow(p.a[s, j], 0.5), 2)
    resid.y.pred[s, j] <- pow(pow(y.pred[s, j], 0.5) - pow(p.a[s, j], 0.5), 2)
    } # End J
    
    # Surveys with Vocalizations
    for (j in 1:J.r[s]) {
  
    # ---------------------------------
    # Vocalizations  
    # ---------------------------------
    v[s, A.times[s, j]] ~ dpois((delta[s, A.times[s, j]] * N[s] + omega) * y[s, A.times[s, j]])
    
    # ---------------------------------
    # Predicted Values  
    # ---------------------------------
    v.pred[s, j] ~ dpois((delta[s, A.times[s, j]] * N[s] + omega) * y[s, A.times[s, j]]) 
    mu.v[s, j] <- ((delta[s, A.times[s, j]] * N[s] + omega)  / (1 - exp(-1 * ((delta[s, A.times[s, j]] * N[s] + omega)))))
    resid.v[s, j] <- pow(pow(v[s, A.times[s, j]], 0.5) - pow(mu.v[s, j], 0.5), 2)
    resid.v.pred[s, j] <- pow(pow(v.pred[s, j], 0.5) - pow(mu.v[s, j], 0.5), 2)
    
    } # End J.r
  } # End S
  
  # ------------------------------------------- 
  # Manual validation 
  # -------------------------------------------
  for (s in 1:S.val) {
    for (j in 1:J.val[s]) {
      K[s, j] ~ dbin(tp[sites.a[s], j], v[sites.a[s], val.times[s, j]])
      k[s, val.times[s, j]] ~ dhyper(K[s, j], v[sites.a[s], val.times[s, j]] - K[s, j], n[s, val.times[s, j]], 1)
    } # End J
  } # End S
  
  # -------------------------------------------
  # Derive Abundance
  # -------------------------------------------
  N_tot <- sum(N[])

  # -------------------------------------------
  # Bayesian P-value
  # -------------------------------------------
  for (s in 1:S.A) {
    tmp.v[s] <- sum(resid.v[sites.a.v[s], 1:J.r[sites.a.v[s]]])
    tmp.v.pred[s] <- sum(resid.v.pred[sites.a.v[s], 1:J.r[sites.a.v[s]]])
  }
  fit.y <- sum(resid.y[sites.a, 1:J.A])
  fit.y.pred <- sum(resid.y.pred[sites.a, 1:J.A])
  fit.v <- sum(tmp.v[1:S.A])
  fit.v.pred <- sum(tmp.v.pred[1:S.A])
  bp.y <- step(fit.y.pred - fit.y)
  bp.v <- step(fit.v.pred - fit.v)
}  
", fill=TRUE, file="./JAGs_Models/Bnet_AV_mod1.txt")
# ------------End Model-------------


# Fit Model
fm.1 <- jags(data = Bnet14.data, 
             inits = inits, 
             parameters.to.save = params, 
             model.file = "./JAGs_Models/Bnet_AV_mod1.txt", 
             n.iter = n.iter,
             n.burnin = n.burnin,
             n.chains = n.chains, 
             n.thin = n.thin,
             parallel = TRUE,
             n.cores = workers,
             DIC = TRUE) 
 
# Check convergence
check_rhat(fm.1$Rhat, threshold = 1.1) # Rhat: less than 1.1 means good convergence

#mcmcplot(fm.1$samples)# Visually inspect trace plots

# Check autocorrelation
#mcmc_list <- as.mcmc.list(lapply(fm.1$samples, as.mcmc))  # Convert each chain separately
#autocorr.diag(mcmc_list)  # Check autocorrelation per chain


# Check Effective Sample Size
#effectiveSize(mcmc_list)

# Check Fit
#cat("Bayesian p-value =", fm.1$summary["p_Bayes",1], "\n")# Best model fit. P-value = 0.5 means good fit, = 1 or 0 is a poor fit

# Model summary
#summary(fm.1$samples)

# -------------------------------------------------------
#
#   Beta Estimates and Covariate Effects 
#
# -------------------------------------------------------

# Combine chains
combined_chains <- as.mcmc(do.call(rbind, fm.1$samples))

# -------------------------------------------------------
# Beta Estimates
# -------------------------------------------------------

# Extract beta estimates
beta0_samples <- combined_chains[, "beta0"]
beta1_samples <- combined_chains[, "beta1"]
beta2_samples <- combined_chains[, "beta2"]
beta3_samples <- combined_chains[, "beta3"]

# Means
beta0 <- mean(beta0_samples)
beta1 <- mean(beta1_samples)
beta2 <- mean(beta2_samples)
beta3 <- mean(beta3_samples)

# Compute 95% CI for each beta
beta_df <- data.frame(
  value = c(beta0_samples, beta1_samples, beta2_samples, beta3_samples),
  parameter = rep(c("beta0", "beta1", "beta2", "beta3"), each = length(beta0_samples))
) %>%
  group_by(parameter) %>%
  filter(value >= quantile(value, 0.025) & value <= quantile(value, 0.975))  # Keep only values within 95% CI

# Add model
beta_df$Model <- model_name

# Plot
ggplot(beta_df, aes(x = parameter, y = value, fill = parameter)) +
  geom_violin(alpha = 0.5, trim = TRUE) +   
  geom_hline(yintercept = 0, linetype = "dashed", color = "black", linewidth = 1) + 
  labs(title = "Violin Plots for Beta Estimates", x
       = "Parameter", 
       y = "Estimate") +
  theme_minimal() +
  scale_fill_brewer(palette = "Set2") 



# Export beta dataframe
saveRDS(beta_df, "./Data/Model_Data/ARU_BnetAV_beta_df.rds")

# -------------------------------------------------------
# Covariate Effects
# -------------------------------------------------------
 
# Covariate names
print(colnames(X.abund))

# Set covariate name 
Cov1_name <- "herb_ClmIdx"
Cov2_name <- "woody_Npatches"

# Create a prediction of covariate values
cov1_pred_vals <- seq(min(X.abund[, Cov1_name]), max(X.abund[, Cov1_name]), length.out = 1000)
cov2_pred_vals <- seq(min(X.abund[, Cov2_name]), max(X.abund[, Cov2_name]), length.out = 1000)

# Mean scaling covariates
cov1_scaled <- (X.abund[, Cov1_name] - mean(X.abund[, Cov1_name])) / (max(X.abund[, Cov1_name]) - min(X.abund[, Cov1_name]))
cov2_scaled <- (X.abund[, Cov2_name] - mean(X.abund[, Cov2_name])) / (max(X.abund[, Cov2_name]) - min(X.abund[, Cov2_name]))

# Matrices for storing predictions
cov1_preds <- matrix(NA, nrow = length(beta0_samples), ncol = length(cov1_scaled))
cov2_preds <- matrix(NA, nrow = length(beta0_samples), ncol = length(cov2_scaled))

# Create a meshgrid of covariate values for interaction predictions
interaction_grid <- expand.grid(cov1_scaled = cov1_scaled, cov2_scaled = cov2_scaled)
interaction_grid$interaction_term <- interaction_grid$cov1_scaled * interaction_grid$cov2_scaled

# Initialize matrix to store predictions
interaction_preds <- matrix(NA, nrow = length(beta0_samples), ncol = nrow(interaction_grid))


# Generate predictions
for (i in 1:length(beta0_samples)) {
  cov1_preds[i, ] <- beta0_samples[i] + beta1_samples[i] * cov1_scaled # Linear
  cov2_preds[i, ] <- beta0_samples[i] + beta2_samples[i] * cov2_scaled
  
  interaction_preds[i, ] <- beta0_samples[i] +                       # Interaction
    beta1_samples[i] * interaction_grid$cov1_scaled +
    beta2_samples[i] * interaction_grid$cov2_scaled +
    beta3_samples[i] * interaction_grid$interaction_term
  
}


# Calculate mean predictions
cov1_preds_mean <- apply(cov1_preds, 2, mean)# mean
cov1_preds_LCI <- apply(cov1_preds, 2, quantile, probs = 0.025) # LCI
cov1_preds_HCI <- apply(cov1_preds, 2, quantile, probs = 0.975) # HCI

cov2_preds_mean <- apply(cov2_preds, 2, mean) 
cov2_preds_LCI <- apply(cov2_preds, 2, quantile, probs = 0.025) 
cov2_preds_HCI <- apply(cov2_preds, 2, quantile, probs = 0.975) 

interaction_preds_mean <- apply(interaction_preds, 2, mean)
interaction_preds_LCI <- apply(interaction_preds, 2, quantile, probs = 0.025)
interaction_preds_HCI <- apply(interaction_preds, 2, quantile, probs = 0.975)

# Combine into a single data frame
cov1_pred_df <- data.frame(
  cov1_scaled = cov1_scaled,
  cov1_preds_mean = cov1_preds_mean,
  cov1_preds_LCI = cov1_preds_LCI,
  cov1_preds_HCI = cov1_preds_HCI)

cov2_pred_df <- data.frame(
  cov2_scaled = cov2_scaled,
  cov2_preds_mean = cov2_preds_mean,
  cov2_preds_LCI = cov2_preds_LCI,
  cov2_preds_HCI = cov2_preds_HCI)

interaction_pred_df <- data.frame(
  interaction_term = interaction_grid$interaction_term,
  cov1_scaled = interaction_grid$cov1_scaled,
  cov2_scaled = interaction_grid$cov2_scaled,
  interaction_preds_mean = interaction_preds_mean,
  interaction_preds_LCI = interaction_preds_LCI,
  interaction_preds_HCI = interaction_preds_HCI)


# Plot effect

# Cov 1
ggplot(cov1_pred_df, aes(x = cov1_scaled, y = cov1_preds_mean)) +
  geom_line(color = "black", linewidth = 1.5) +   
  geom_ribbon(aes(ymin = cov1_preds_LCI, 
                  ymax = cov1_preds_HCI), 
              fill = "forestgreen", alpha = 0.3) +
  labs(x = "Covariate Value", 
       y = "Effect Estimate", 
       title = paste0(model_name, " | Predicted Effect of ", Cov1_name)) +
  theme_minimal() +
  theme(panel.grid = element_blank())

# Cov 2
ggplot(cov2_pred_df, aes(x = cov2_scaled, y = cov2_preds_mean)) +
  geom_line(color = "black", linewidth = 1.5) +   
  geom_ribbon(aes(ymin = cov2_preds_LCI, 
                  ymax = cov2_preds_HCI), 
              fill = "forestgreen", alpha = 0.3) +
  labs(x = "Covariate Value", 
       y = "Effect Estimate", 
       title = paste0(model_name, " | Predicted Effect of ", Cov2_name)) +
  theme_minimal() +
  theme(panel.grid = element_blank())


# Interactive effects
plot_ly(interaction_pred_df, 
        x = ~cov1_scaled, 
        y = ~cov2_scaled, 
        z = ~interaction_preds_mean, 
        type = "contour",
        colorscale = "Viridis",
        ncontours = 80,
        contours = list(showlabels = FALSE), 
        colorbar = list(title = "Interaction Effect", titlefont = list(size = 14)) 
        )%>%
          layout(
            title = list(
              text = paste0(model_name, " | Interaction Effect "),
              font = list(size = 18),  
              x = 0.5,   
              xanchor = "center"   
            ),
            xaxis = list(
              title = list(text = "Herbaceous Clumpy Index (scaled)", 
                           font = list(size = 14))),
            yaxis = list(
              title = list(text = "Woody Number of Patches (scaled)", 
                           font = list(size = 14))))


# -------------------------------------------------------
# Estimating Abundance 
# -------------------------------------------------------


# Extracting Abundance
Ntot_samples <- combined_chains[ ,"N_tot"]

# Ntotal is the abundance based on 10 point counts at a radius of 200m.
# To correct for density, Ntotal needs to be divided by 10 * area surveyed
area <- pi * (250^2) / 4046.86  # Area in acres
dens_samples <- Ntot_samples / (area * 10)

# Create data frame for density
dens_df <- data.frame(Model = rep(model_name, length(dens_samples)), Density = dens_samples)
colnames(dens_df)[2] <- "Density"
head(dens_df)

# Calculate the mean and 95% Credible Interval
dens_summary <- dens_df %>%
  group_by(Model) %>%
  summarise(
    Mean = mean(Density),
    Lower_CI = quantile(Density, 0.025),
    Upper_CI = quantile(Density, 0.975)
  )

# Subset the data within the 95% credible interval
dens_df <- dens_df[dens_df$Density >= dens_summary$Lower_CI 
                   & dens_df$Density <= dens_summary$Upper_CI, ]


# Getting total abundance
abund_summary <- dens_summary
abund_summary[,2:4] <- abund_summary[,2:4] * 2710

# Plot Abundance - Violin
abund_df <- dens_df
abund_df$Density <- abund_df$Density * 2710

ggplot(abund_df, aes(x = Model, y = Density, fill = Model)) + 
  geom_violin(trim = FALSE, alpha = 0.6, adjust = 5) +  # Adjust bandwidth for smoothing
  labs(x = "Model", y = "Density (N/acre)") +
  scale_fill_manual(values = c("AV Bnet" = "blue")) +  # Custom colors
  scale_y_continuous(limits = c(0, 1000),
                     breaks = seq(0, 1000, by = 100),
                     labels = scales::comma) +
  theme_minimal() +
  theme(axis.text.x = element_text(angle = 45, hjust = 1, face = "bold"),  
        axis.title.x = element_text(face = "bold", margin = margin(t = 10)),  
        axis.title.y = element_text(face = "bold", margin = margin(r = 10)),
        panel.grid = element_blank(),
        legend.position = "none")  # Removes legend



# Total abundance
abund_summary




# Export density dataframe
saveRDS(dens_df, "./Data/Model_Data/ARU_BnetAV_dens_df.rds")
saveRDS(dens_summary, "./Data/Model_Data/ARU_BnetAV_dens_summary.rds")
saveRDS(abund_summary, "./Data/Model_Data/ARU_BnetAV_abund_summary.rds")



# Save Environment
# save.image(file = "./Data/Model_Environments/ARU_AV_Bnet14day_JAGs.RData")

# End Script