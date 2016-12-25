############################################################################################################
####### DEVELOP SPATIAL AGGREGATION INDEX FOR SEABIRDS   ###################################################################
############################################################################################################
## this analysis is based on BirdLife International marine IBA processing scripts
## developed by steffen.oppel@rspb.org.uk in December 2016
## data provided by ana.carneiro@birdlife.org on 12 Dec 2016
## fixed some mIBA_script issues on 14 Dec 2016
## added function to remove duplicate time values on 14 Dec 2016
## initial phase to explore approaches

## v2 on 16 Dec 2016 includes major update/fix of marine IBA scripts for polyCount and batchUD - see marineIBA_function_fixes.r for attempts
## 20 Dec 2016: fixed projection problem by changing wgs84 to WGS84; FIXED polyCount function and NA problem in Morisita input values

## v3 on 22 Dec 2016 includes revision of polyCount function to return all cells and not just occupied cells
## removed parallel computation because it resulted in downstream processing issues and time gain was marginal or negative

## v4 on 22 Dec 2016 improves batchUD function to use adehabitatHR and various overlap indices
## updated v4 on 25 Dec to include final ranking and switch overlap index from mean to median


## NEED TO DO: CHECK SAMPLE SIZE CORRECTION FOR INDEX!! CHECK WHY kerneloverlap >1

## for spatial aggregation indices see : http://life.mcmaster.ca/~brian/evoldir/Answers/Aggregation.answers
## https://cran.r-project.org/web/views/Spatial.html

## based on Stats Club Discussion on 9 Dec we could proceed as follows:

1. Split trips, assess FTP and calculate home ranges for each individual
2. Use polycount output for spatial aggregation index

3. Loop over spatial scales from 100 m to 10000 km
4. For each spatial scale, draw 100 random samples of sample sizes 5,10,15,25,40
5. calculate polycount for each spatial scale
6. use values from polycount in dispindmorisita to calculate Morisita's index
7. plot Morisita's index (y-axis) over all spatial scales (x-axis) with different sample sizes (different points)
8. Fit non-linear function and determine the point at which the asymptote is reached (same function as for sample size assessment in bootstrap)

## Expectation is that the scale at which the asymptote is reached will separate species with scattered distributions from this with more aggregated distributions.







#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# LOAD PACKAGES AND CUSTOM SCRIPTS
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
library(Hmisc)
require(maps)
require(mapdata)
require(adehabitatHR)
require(foreign)
require(maptools)
require(geosphere)
require(sp)
library(rgdal)
require(rgeos)
library(raster)
library(trip)
library(rworldmap)
library(plyr)
library(vegan)
library(adehabitatLT)
data(countriesLow)
library(inflection)
library(spatstat)

source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\mIBA_functions_upd2016.r")
source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\SeabirdPrioritisation\\seabird_index.r")




#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# LOAD DATA FROM BIRDLIFE DATABASE AND MODIFY DATA TO MEET REQUIREMENTS FOR PROCESSING
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Load data from database
setwd("A:\\RSPB\\Marine\\SeabirdPrioritisation")
alldat<-read.table("Steffen_Spp_Prioritisation_Project_2016-12-12.csv", header=T, sep=",")
head(alldat)
dim(alldat)


### Convert Dates and Times and calculate the time difference (in s) between each location and the first location of that deployment
alldat$Time<-format(alldat$time_gmt,format="%H:%M:%S")
alldat$Date<-as.Date(alldat$date_gmt,format="%d/%m/%Y")
alldat$Loctime<-as.POSIXlt(paste(alldat$Date, alldat$Time), format = "%Y-%m-%d %H:%M:%S")
alldat$DateTime <- as.POSIXct(strptime(alldat$Loctime, "%Y-%m-%d %H:%M:%S"), "GMT")
alldat$TrackTime <- as.double(alldat$DateTime)
names(alldat)

alldat<-alldat[,c(1,2,4,6:10,12:14,19,18,24:25)]
names(alldat)[c(8,13:12)]<-c('ID','Latitude','Longitude')
head(alldat)





#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# PLOT THE DATA TO CHECK THAT IT LOOKS OK
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

xlow<-min(alldat$Longitude)+0.2
xup<-max(alldat$Longitude)-0.2
yup<-max(alldat$Latitude)-0.5
ylow<-min(alldat$Latitude)+0.5

windows(600,400)
plot(Latitude~Longitude, data=alldat, pch=16, cex=0.3,col=dataset_id, asp=1, xlim=c(xlow,xup), ylim=c(ylow,yup), main="", frame=F, axes=F, xlab="", ylab="")
plot(countriesLow, col='darkgrey', add=T)






#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# ASSESS THE NUMBER OF DATA GROUPS (Species * Colony * life history stage) and create output table
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### Create Overview table and assign data groups of equal species, site,age, and life history stage:
overview <- ddply(alldat, c("scientific_name","site_name","age","breed_stage"), summarise,n_individuals=length(unique(bird_id)), n_tracks=length(unique(ID)))
overview$DataGroup<-seq(1:dim(overview)[1])
alldat<-merge(alldat,overview[,c(1:4,7)],by=c("scientific_name","site_name","age","breed_stage"), all.x=T)


### CREATE SPATIAL SCALES FOR ANALYSIS
### order not ascending so that parallel loop will not calculate the most demanding subsets simultaneously
spatscales<-exp(seq(0,9.5,0.5))			## on log scale
spatscales<-c(2.5,500,1000,1500,5,100,150,250,7.5,10,12.5,15,17.5,20,25,30,40,50,75)			## in km
#spatscales<-c(500,30,1000,1500,40,75,100,250,5,10,15,20,50)			## in km
spatscales<-spatscales/100			### roughly in decimal degrees, as required for the polyCount function


### Create Table that includes one line for each DataGroup at each spatial scale
### THIS WILL NEED A MANUAL ADJUSTMENT FOR THE TripSPlit function

outI<-expand.grid(overview$DataGroup,spatscales)			### sets up the lines for which we need to calculate Morisita's I
names(outI)<-c("DataGroup","Scale")



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# COMBINE OVERVIEW TABLE WITH FAMILY INFO AND SET TRIP SPLIT PARAMETERS
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

setwd("A://RSPB/Marine/GlobalSeabirdDistribution")
setwd("C:\\STEFFEN\\RSPB\\Marine\\GlobalSeabirdDistribution")
species_list<-read.table("SeabirdRangeMaps_SpeciesList.csv", header=T, sep=',')
species_list$GISname<-paste(substr(species_list$Family,1,3), species_list$SpcRecID, sep='')
head(species_list)
head(overview)

overview$Family<-species_list$Family[match(overview$scientific_name, species_list$Scientific_name)]
overview$Seabird_type<-species_list$Seabird_type[match(overview$scientific_name, species_list$Scientific_name)]
overview$device<-alldat$device[match(overview$scientific_name, alldat$scientific_name)]

overview$InnerBuff<-ifelse(overview$device=="PTT",10,ifelse(overview$Seabird_type=="Pelagic seabird", 5,0.5))
overview$ReturnBuff<-ifelse(overview$device=="PTT",50,ifelse(overview$Seabird_type=="Pelagic seabird", 50,5))
overview$Duration<-ifelse(overview$device=="PTT",10,ifelse(overview$Seabird_type=="Pelagic seabird", 5,1))






#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# START LOOP OVER EACH DATA GROUP
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

OUTPUT<-data.frame()							### set up blank frame to collate Morisita index values
SUMMARY<-data.frame()							### set up blank frame to collate inflection point summaries
OL_INDEX<-data.frame()							### set up blank frame to collect overlap indices for each data set

for (dg in 1:max(overview$DataGroup)){


#### SELECT DATA FOR ANALYSIS AND ORDER BY TIME AND REMOVE DUPLICATE TIME STAMPS ##########################
tracks<-alldat[alldat$DataGroup==dg,]
tracks<-tracks[order(tracks$ID, tracks$TrackTime),]
tracks$TrackTime<-adjust.duplicateTimes(tracks$TrackTime, tracks$ID)




windows(600,400)
plot(Latitude~Longitude, data=tracks, pch=16, cex=0.3,asp=1, col=tracks$ID)
plot(countriesLow, col='red', add=T)



#### CREATE COLONY LOCATION AND APPROPRIATE COORDINATE REFERENCE SYSTEM FOR PROJECTION ##########################
loc<-aggregate(lat_colony~ID, data=tracks, FUN=mean)		## Colony location is mean of all nest locations
loc$lon_colony<-aggregate(lon_colony~ID, data=tracks, FUN=mean)[,2]
names(loc)[2:3]<-c('Latitude','Longitude')





#### IF SPARSE DATA (PTT)THEN INTERPOLATE TO EVERY 1 HR 
if(tracks$device[1]=="PTT"){
traj <- as.ltraj(xy=data.frame(tracks$Longitude, tracks$Latitude), date=as.POSIXct(tracks$TrackTime, origin="1970/01/01", tz="GMT"), id=tracks$ID, typeII = TRUE)

## Rediscretization every 3600 seconds
tr <- adehabitatLT::redisltraj(traj, 3600, type="time")

## Convert output into a data frame
tracks.intpol<-data.frame()
for (l in 1:length(unique(tracks$ID))){
out<-tr[[l]]
out$MID<-as.character(attributes(tr[[l]])[4])				#### extracts the MigID from the attribute 'id'
tracks.intpol<-rbind(tracks.intpol,out)				#### combines all data
}

### re-insert year and season

tracks.intpol$age<-tracks$age[match(tracks.intpol$MID,tracks$ID)]
tracks.intpol$bird_id<-tracks$bird_id[match(tracks.intpol$MID,tracks$ID)]
tracks.intpol$sex<-tracks$sex[match(tracks.intpol$MID,tracks$ID)]
tracks.intpol$TrackTime <- as.double(tracks.intpol$date)

## recreate data frame 'tracks' that is compatible with original data
tracks<-data.frame(scientific_name=tracks$scientific_name[1],
		site_name=tracks$site_name[1],
		age=tracks.intpol$age,
		breed_stage=tracks$breed_stage[1],
		dataset_id=tracks$dataset_id[1],
		device="PTT",
		bird_id=tracks.intpol$bird_id,
		ID=tracks.intpol$MID,
		sex=tracks.intpol$sex,
		Longitude=tracks.intpol$x,
		Latitude=tracks.intpol$y,
		DateTime=tracks.intpol$date,
		TrackTime=tracks.intpol$TrackTime,
		DataGroup=dg)
		

tracks<-tracks[order(tracks$ID, tracks$TrackTime),]
tracks$TrackTime<-adjust.duplicateTimes(tracks$TrackTime, tracks$ID)

}			## close IF loop for PTT tracks



### PROJECT COORDINATES FOR SPATIAL ANALYSES - this now needs WGS84 in CAPITAL LETTERS (not wgs84 anymore!!)
### SpatialPointsDataFrame cannot contain POSIXlt data type!

DataGroup.Wgs <- SpatialPoints(data.frame(tracks$Longitude, tracks$Latitude), proj4string=CRS("+proj=longlat +datum=WGS84"))
input <- SpatialPointsDataFrame(SpatialPoints(data.frame(tracks$Longitude, tracks$Latitude), proj4string=CRS("+proj=longlat +datum=WGS84")), data = tracks, match.ID=F)
DgProj <- CRS(paste("+proj=laea +lon_0=", loc$Longitude, " +lat_0=", loc$Latitude, sep=""))
DataGroup.Projected <- spTransform(input, CRS=DgProj)
input <- DataGroup.Projected
localmap<-spTransform(countriesLow, CRS=DgProj) 




#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# SPLIT INTO FORAGING TRIPS
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

Trips <- NULL
for(i in 1:length(unique(tracks$ID)))
  {
  	Temp <- subset(input, ID == unique(tracks$ID)[i])
	Trip <- tripSplit(Track=Temp, Colony=loc[loc$ID==unique(tracks$ID)[i],2:3], InnerBuff=overview$InnerBuff[overview$DataGroup==dg], ReturnBuff=overview$ReturnBuff[overview$DataGroup==dg], Duration = overview$Duration[overview$DataGroup==dg], plotit=T, nests=F)
  	if(i == 1) {Trips <- Trip} else
  	Trips <- spRbind(Trips,Trip)
  }


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CALCULATE SCALE FOR AREA RESTRICTED SEARCH
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
DataGroup <- Trips
#head(Trips@data)
ScaleOut <- scaleARS(DataGroup[DataGroup@data$trip_id!="-1",], Scales = c(seq(0, 50, 0.5)), Peak="Flexible")
# consider replacing this with 10 km uniformly across all species to keep results consistent?
#ScaleOut <- 10


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DELINEATE CORE AREAS (KERNEL DENSITY ESTIMATOR - 50% Utilisation Distribution)
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
UD<-50		## pick the % utilisation distribution (50%, 95% etc.)
Output <- batchUDOL(DataGroup[DataGroup@data$trip_id!="-1",], Scale = ScaleOut/2, UDLev = UD)
plot(localmap, col='darkolivegreen3', add=T)
OLindex<-Output$OverlapIndex
OLindex$DataGroup<-dg



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CALCULATE RIPLEY'S K
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
bbox(input)[1,]
points<-coordinates(DataGroup[DataGroup@data$trip_id!="-1",])
mypattern <- ppp(points[,1], points[,2], bbox(input)[1,], bbox(input)[2,])
RipK<-Kest(mypattern)
maxK<-max(RipK$border)
OLindex$Rip_K<-min(RipK$r[RipK$border==maxK])
OL_INDEX<-rbind(OL_INDEX,OLindex)



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# START LOOP OVER EACH SPATIAL SCALE
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

outMorisita<-data.frame()
for (sc in spatscales){


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# COUNTING THE POLYGONS AND CALCULATING SPATIAL DISPERSION INDEX
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

temp<-spatInd(Output$UDpolygons, Res = sc)				### resolution in decimal degrees
temp$DataGroup<-dg
outMorisita<-rbind(outMorisita,temp)
} ### end loop over spatial scales

OUTPUT<-rbind(OUTPUT,outMorisita)
dev.off()

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CALCULATE INFLECTION POINT AND ASYMPTOTE FOR DATA SET - NaN output - removed on 23 Dec 2016
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#Morisummary<-data.frame(DataGroup=dg,inflection=0,asymptote=0)
#EDE<-bede(outMorisita$Scale,outMorisita$imst,0)
#asymp<-bese(outMorisita$Scale,outMorisita$imst,1)
#Morisummary$inflection<-EDE$iters$EDE[1]
#Morisummary$asymptote<-asymp$iters$ESE
#SUMMARY<-rbind(SUMMARY,Morisummary)

} ### end loop over species 



########################################







#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# IDENTIFYING THE SPATIAL SCALE SLOPE ACROSS ALL DATA
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~



### loop over each data group ###
overview$slope<-0
overview$p<-0
overview$maxMorisita<-0

for (dg in overview$DataGroup){
x<-OUTPUT[OUTPUT$DataGroup==dg,]
m1<-lm(Morisita~log(Scale*100), data=x)
overview$slope[overview$DataGroup==dg]<-m1$coefficients[2]
#overview$p[overview$DataGroup==dg]<-m1$coefficients[2,4]
overview$maxMorisita[overview$DataGroup==dg]<-max(x$Morisita, na.rm=T)
}


### SORT SPECIES BY SLOPE
overview<-overview[order(overview$slope, decreasing=F),]





#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# INSPECTING OUTPUT: BARPLOTS FOR OVERLAP INDICES AND RIPLEYS K
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### for overall results
OL_INDEX$Species<-overview$scientific_name[match(OL_INDEX$DataGroup,overview$DataGroup)]
OL_INDEX<-OL_INDEX[order(OL_INDEX$Rip_K, decreasing=F),]
head(OL_INDEX)



######### PLOT RIPLEY'S K ASYMPTOTE - THE MOST PROMISING APPROACH #######################

ggplot(OL_INDEX[OL_INDEX$method=="VI",], aes(x=DataGroup, y=log(Rip_K/1000)), size=2)+
geom_bar(stat="identity")+
  xlab("Species") +
  ylab("Spatial scale of Ripley's K asymptote (km)") +
  scale_x_discrete(limits=as.character(unique(OL_INDEX$DataGroup)),labels=c("RAZO","RAZO","FRIG","FRIG","RBTB","RBTB","SHAG","SHAG","SOAL","MUPE","MABO","MABO","MABO","MABO","CGUIL","CGUIL"))+
  theme(panel.background=element_rect(fill="white", colour="black"),
	axis.text.x = element_text(face="bold", color="#993333", size=14, angle=45), 
        axis.text.y=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())




###### PLOT OVERLAP INDICES - RBTB IS OUTLIER ####

ggplot(OL_INDEX, aes(x=DataGroup, y=mean_index), size=2)+
geom_bar(stat="identity")+facet_wrap("method", ncol=3, scales = "free")+
  xlab("Species") +
  ylab("Value of overlap index") +
  scale_x_discrete(limits=as.character(unique(OL_INDEX$DataGroup)),labels=c("RAZO","RAZO","FRIG","FRIG","RBTB","RBTB","SHAG","SHAG","SOAL","MUPE","MABO","MABO","MABO","MABO","CGUIL","CGUIL"))+
  theme(panel.background=element_rect(fill="white", colour="black"), 
        axis.text.x = element_text(color="#993333", size=8, angle=90), 
        axis.text.y=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())

### FOR JUST ONE INDEX ####

ggplot(OL_INDEX[OL_INDEX$method=="BA",], aes(x=DataGroup, y=mean_index), size=2)+
geom_bar(stat="identity")+
  xlab("Species") +
  ylab("Value of overlap index") +
  scale_x_discrete(limits=as.character(unique(OL_INDEX$DataGroup)),labels=c("RAZO","RAZO","FRIG","FRIG","RBTB","RBTB","SHAG","SHAG","SOAL","MUPE","MABO","MABO","MABO","MABO","CGUIL","CGUIL"))+
  theme(panel.background=element_rect(fill="white", colour="black"),
	axis.text.x = element_text(face="bold", color="#993333", size=14, angle=45), 
        axis.text.y=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())






######### PLOT MAX MORISITA AND SLOPE #######################

ggplot(overview, aes(x=DataGroup, y=maxMorisita, size=2))+
geom_bar(stat="identity")+
  xlab("Species") +
  ylab("maximum of Morisita index") +
  scale_x_discrete(limits=as.character(unique(overview$DataGroup)),labels=c("RAZO","RAZO","FRIG","FRIG","RBTB","RBTB","SHAG","SHAG","SOAL","MUPE","MABO","MABO","MABO","MABO","CGUIL","CGUIL"))+
  theme(panel.background=element_rect(fill="white", colour="black"),
	axis.text.x = element_text(face="bold", color="#993333", size=14, angle=45), 
        axis.text.y=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"),
        legend.position="none",
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())










#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# INSPECTING OUTPUT: EXPLORING VARIOUS SLOPES ACROSS SPECIES
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

### for overall results
OUTPUT$Species<-overview$scientific_name[match(OUTPUT$DataGroup,overview$DataGroup)]
OUTPUT$DataGroup<-as.factor(OUTPUT$DataGroup)
levels(OUTPUT$DataGroup) <- paste(c("RAZO","RAZO","FRIG","FRIG","RBTB","RBTB","SHAG","SHAG","SOAL","MUPE","MABO","MABO","MABO","MABO","CGUIL","CGUIL"),OUTPUT$DataGroup,sep="")
#OUTPUT$DataGroup<-as.numeric(rep(c(1:16), length(spatscales)))
OUTPUT<-OUTPUT[order(OUTPUT$Scale),]
smallOUT<-OUTPUT[OUTPUT$Scale<6,]

ggplot(OUTPUT, aes(x=log(Scale*100), y=Morisita), size=2)+
geom_smooth(fill="lightblue", size=1.5)+facet_wrap("DataGroup", ncol=4, scales = "free")+
  geom_point(colour="black", size=2.5) +
  xlab("log(spatial scale (km))") +
  ylab("Morisita aggregation index") +
  theme(panel.background=element_rect(fill="white", colour="black"), 
        axis.text=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())



ggplot(OUTPUT, aes(x=log(Scale*100), y=imst), size=2)+
geom_smooth(fill="lightblue", size=1.5)+facet_wrap("DataGroup", ncol=4)+
  geom_point(colour="black", size=2.5) +
  xlab("log(spatial scale (km))") +
  ylab("Standardised morisita index") +
  theme(panel.background=element_rect(fill="white", colour="black"), 
        axis.text=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())


ggplot(smallOUT, aes(x=log(Scale*100), y=imst), size=2)+
geom_smooth(fill="lightblue", size=1.5)+facet_wrap("Species", ncol=4)+
  geom_point(colour="black", size=2.5) +
  xlab("log(spatial scale (km))") +
  ylab("Standardised morisita index") +
  theme(panel.background=element_rect(fill="white", colour="black"), 
        axis.text=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())



ggplot(OUTPUT, aes(x=Scale*100, y=pchisq), size=2)+
geom_line(colour="lightblue", size=1.5)+facet_wrap("DataGroup", ncol=4)+
  geom_point(colour="black", size=2.5) +
  xlab("Spatial scale (km)") +
  ylab("p-value of Morisita index") +
  theme(panel.background=element_rect(fill="white", colour="black"), 
        axis.text=element_text(size=18, color="black"), 
        axis.title=element_text(size=20), 
        strip.text.x=element_text(size=18, color="black"), 
        strip.background=element_rect(fill="white", colour="black"), 
        panel.grid.major = element_blank(), 
        panel.grid.minor = element_blank(), 
        panel.border = element_blank(), 
        panel.background = element_blank())


####







#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# PRODUCE FINAL RANKING TABLE BASED ON max Morisita, Ripley's K, foraging range, and BA overlap index
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

FINAL<-overview[,c(7,8,1,3,4,14,16)]
names(FINAL)[3]<-"Species"
FINAL<-merge(FINAL,OL_INDEX[OL_INDEX$method=="BA",c(4,6,2,5)], by=c("DataGroup","Species"))
addfinal<-aggregate(extent~DataGroup, OUTPUT, FUN="max")
addfinal$range<-(addfinal$extent)*((min(spatscales)*100)^2)			### range in square kilometers

FINAL<-merge(FINAL,addfinal, by=c("DataGroup"))



##### ORDER BY DIFFERENT INDICES AND ASSIGN RANKING #####

FINAL$MorisRank<-rank(-FINAL$maxMorisita, ties.method = "min")
FINAL$BARank<-rank(-FINAL$mean_index, ties.method = "min")
FINAL$RipKRank<-rank(FINAL$Rip_K, ties.method = "min")
FINAL$RangeRank<-rank(FINAL$range, ties.method = "min")
FINAL$MedianRank<-apply(FINAL[,c(12:15)],1,median)

FINAL<-FINAL[order(FINAL$MedianRank, decreasing=F),]			## CHANGE RANKING BASED ON SPECIES-SPECIFIC APPROACH




#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# EXPORT OUTPUT
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

setwd("A:\\RSPB\\Marine\\SeabirdPrioritisation")
write.table(FINAL,"SeabirdPrioritisation_OUT.csv", row.names=F, sep=",")
save.image("A:\\RSPB\\Marine\\SeabirdPrioritisation\\AggIndex_output_v4.RData")
