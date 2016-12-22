############################################################################################################
####### DEVELOP SPATIAL AGGREGATION INDEX FOR SEABIRDS   ###################################################################
############################################################################################################
## this analysis is based on BirdLife International marine IBA processing scripts
## developed by steffen.oppel@rspb.org.uk in December 2016
## data provided by ana.carneiro@birdlife.org on 12 Dec 2016
## fixed some mIBA_script issues on 14 Dec 2016
## added function to remove duplicate time values on 14 Dec 2016
## initial phase to explore approaches

## NEED TO DO: parallelise sc loop, create automated selection of TripSplit values for species/tag combinations



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
require(adehabitat)
require(foreign)
require(maptools)
require(geosphere)
require(sp)
require(rgdal)
require(rgeos)
library(raster)
library(trip)
library(rworldmap)
library(plyr)
library(vegan)
library(parallel)
library(foreach)
library(adehabitatLT)
data(countriesLow)


#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Statistics\\northarrow.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Statistics\\scalebar.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\tripSplit.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\tripSummary.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\scaleARS.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\BatchUD.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\Bootstrap.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\Bootstrap.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\polyCount.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\thresholdRaster.r")
#source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\varianceTest.r")
source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\mIBA_functions_upd2016.r")





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

alldat<-alldat[,c(1,3,4,6:10,12:14,19,18,24:25)]
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
overview <- ddply(alldat, c("common_name","site_name","age","breed_stage"), summarise,n_individuals=length(unique(bird_id)), n_tracks=length(unique(ID)))
overview$DataGroup<-seq(1:dim(overview)[1])
alldat<-merge(alldat,overview[,c(1:4,7)],by=c("common_name","site_name","age","breed_stage"), all.x=T)


### CREATE SPATIAL SCALES FOR ANALYSIS
### order not ascending so that parallel loop will not calculate the most demanding subsets simultaneously
spatscales<-exp(seq(0,9.5,0.5))			## on log scale
spatscales<-c(0.5,1,1.5,2.5,5,7.5,10,12.5,15,17.5,20,25,30,40,50,75,100,150,250,500,1000,1500,2500,5000,10000)			## in km
spatscales<-c(1,500,1000,1500,2.5,75,100,250,5,10,15,20,50)			## in km
spatscales<-spatscales/100			### roughly in decimal degrees, as required for the polyCount function


### Create Table that includes one line for each DataGroup at each spatial scale
### THIS WILL NEED A MANUAL ADJUSTMENT FOR THE TripSPlit function

out<-expand.grid(overview$DataGroup,spatscales)			### sets up the lines for which we need to calculate Morisita's I
names(out)<-c("DataGroup","Scale")
OUTPUT<-data.frame()							### set up blank frame to write output from parallelised loop




#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# START LOOP OVER EACH DATA GROUP
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~



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
tr <- redisltraj(traj, 3600, type="time")

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
tracks<-data.frame(common_name=tracks$common_name[1],
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



### PROJECT COORDINATES FOR SPATIAL ANALYSES
### SpatialPointsDataFrame cannot contain POSIXlt data type!

DataGroup.Wgs <- SpatialPoints(data.frame(tracks$Longitude, tracks$Latitude), proj4string=CRS("+proj=longlat + datum=wgs84"))
DgProj <- CRS(paste("+proj=laea +lon_0=", loc$Longitude, " +lat_0=", loc$Latitude, sep=""))
DataGroup.Projected <- spTransform(DataGroup.Wgs, CRS=DgProj)
input <- SpatialPointsDataFrame(DataGroup.Projected, data = tracks)
localmap<-spTransform(countriesLow, CRS=DgProj) 








#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# SPLIT INTO FORAGING TRIPS
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


Trips <- NULL


for(i in 1:length(unique(tracks$ID)))
  {
  	Temp <- subset(input, ID == unique(tracks$ID)[i])
	Trip <- tripSplit(Track=Temp, Colony=loc[loc$ID==unique(tracks$ID)[i],2:3], InnerBuff=5, ReturnBuff=50, Duration = 5, plotit=T, nests=F)
  	if(i == 1) {Trips <- Trip} else
  	Trips <- spRbind(Trips,Trip)
  }

#str(Trips)
dim(Trips)



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CALCULATE SCALE FOR AREA RESTRICTED SEARCH
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
DataGroup <- Trips
head(Trips@data)
#ScaleOut <- scaleARS(DataGroup[DataGroup@data$trip_id!="-1",], Scales = c(seq(0, 50, 0.5)), Peak="Flexible")
# consider replacing this with 10 km uniformly across all species to keep results consistent?
ScaleOut <- 20


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# DELINEATE CORE AREAS (KERNEL DENSITY ESTIMATOR - 50% Utilisation Distribution)
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
UD<-50		## pick the % utilisation distribution (50%, 95% etc.)
Output <- batchUD(DataGroup[DataGroup@data$trip_id!="-1",], Scale = ScaleOut/2, UDLev = UD)
plot(localmap, col='darkolivegreen3', add=T)





#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# START LOOP OVER EACH SPATIAL SCALE
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


#setup parallel backend to use 4 processors
cl<-makeCluster(8)
registerDoParallel(cl)


outMorisita<-foreach(sc=spatscales,.combine=rbind, .packages=c("vegan","sp","rgdal")) %dopar% {
#outMorisita<-data.frame()
#for (sc in spatscales){

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# COUNTING THE POLYGONS
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
source("S:\\ConSci\\DptShare\\SteffenOppel\\RSPB\\Marine\\IBA\\Analysis\\mIBA_functions_upd2016.r")
ASI<-polyCount(Output, Res = sc)				### resolution in decimal degrees



#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# CREATE DATA FRAME FOR MORISITA SPATIAL INDEX FROM polyCount output
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
temp<-out[out$DataGroup==dg & out$Scale==sc,]
nind<-length(unique(DataGroup$ID[DataGroup@data$trip_id!="-1"]))
index<- as.numeric(dispindmorisita(ASI@data@values*nind))
temp$Morisita<- index[1]
temp$mclu<- index[2]
temp$muni<- index[3]
temp$imst<- index[4]
temp$pchisq<- index[5]
#row.names(temp)<-c()
#row.names(outMorisita)<-NULL
return(temp)
outMorisita<-rbind(outMorisita,temp)
} ### end loop over spatial scales
stopCluster(cl)


OUTPUT<-rbind(OUTPUT,out$Morisita)


} ### end loop over species 





sys.time()
system.time()







######################### FIXING THE POLY COUNT FUNCTION ##################################################################################################

### MAJOR ISSUES WITH ORPHANED HOLES IN kernelUD output




### TRYING TO CLEAN ORPHANED HOLES ####

Polys=Output
Res=3

  # clean geometry of polygons - might be better to insert into batchUD function!?

report <- clgeo_CollectionReport(Polys)
summary <- clgeo_SummaryReport(report)
issues <- report[report$valid == FALSE,]
if(dim(issues)[1]>0){print(paste("NOTE - there is a geometry problem:",issues$error_msg, sep=" "))}

#get suspicious features (indexes)
nv <- clgeo_SuspiciousFeatures(report)
mysp <- Polys[nv[-14],]

#try to clean data
mysp.clean <- clgeo_Clean(mysp)

#check if they are still errors
report.clean <- clgeo_CollectionReport(mysp.clean)
summary.clean <- clgeo_SummaryReport(report.clean)

dim(Polys)
dim(mysp.clean)			### WORKS BUT REMOVES A LOT PF POLYGONS


###### try different approach #

outerRings = Filter(function(f){f@ringDir==1},Polys@polygons[[1]]@Polygons)
outerBounds = SpatialPolygons(list(Polygons(outerRings,ID=1)))
plot(outerBounds)


clean.Polys<-SpatialPolygonsDataFrame()
  for(i in 1:length(Polys))
    {
outerRings = Filter(function(f){f@ringDir==1},Polys@polygons[[i]]@Polygons)

	outerBounds = SpatialPolygons(list(Polygons(outerRings,ID=i)))
	outerBounds = SpatialPolygonsDataFrame(outerBounds, data = as(outerBounds, "data.frame"))
	if(i==1){clean.Polys<-outerBounds}
	clean.Polys<-spRbind(clean.Polys,outerBounds)
	}
plot(outerBounds)

### fails at re-combining the polygons



#### third approach #####


va90a <- spChFIDs(Output, paste(Output$Name_0, Output$Name_1, Output$ID, sep = ""))
va90a <- va90a[, -(1:4)]
va90_pl <- slot(va90a, "polygons")
va90_pla <- lapply(va90_pl, checkPolygonsHoles)
p4sva <- CRS(proj4string(va90a))
vaSP <- SpatialPolygons(va90_pla, proj4string = p4sva)
va90b <- SpatialPolygonsDataFrame(vaSP, data = as(va90a, "data.frame"))
va90b@data<-Output@data

Polys<-va90b

##########


polyCount <- function(Polys, Res = 0.1)
  {

  require(raster)
  require(maps)
  require(cleangeo)

  if(!class(Polys) %in% c("SpatialPolygonsDataFrame", "SpatialPolygons")) stop("Polys must be a SpatialPolygonsDataFrame")
  if(is.na(projection(Polys))) stop("Polys must be projected")


Polys<-mysp.clean 


  Poly.Spdf <- spTransform(Polys, CRS=CRS("+proj=longlat +ellps=WGS84"))
  DgProj <- Polys@proj4string

  DateLine <- Poly.Spdf@bbox[1,1] < -178 & Poly.Spdf@bbox[1,2] > 178
  if(DateLine == TRUE) {print("Data crosses DateLine")}

  UDbbox <- bbox(Poly.Spdf)
  if(DateLine == TRUE)  {UDbbox[1,] <- c(-180,180)}
  BL <- floor(UDbbox[,1])
  TR <- ceiling(UDbbox[,2])
  NRow <- ceiling(sqrt((BL[1] - TR[1])^2)/Res)
  NCol <- ceiling(sqrt((BL[2] - TR[2])^2)/Res) #+ (Res * 100)				### THIS LINE CAUSES PROBLEMS BECAUSE IT GENERATES LATITUDES >90 which will cause spTransform to fail
  Grid <- GridTopology(BL, c(Res,Res), c(NRow, NCol))
newgrid<-SpatialGrid(Grid, proj4string = CRS("+proj=longlat + datum=wgs84"))
spol <- as(newgrid, "SpatialPolygons")								### this seems to create an orphaned hole
SpGridProj <- spTransform(spol, CRS=DgProj)
GridIntersects <- over(SpGridProj, Polys)

SpGridProj<- SpatialPolygonsDataFrame(SpGridProj, data = data.frame(ID=GridIntersects$ID, row.names=sapply(SpGridProj@polygons,function(x) x@ID)))
#  SpGridProj@data$Intersects$ID <- GridIntersects$ID
SpGridProj <- subset(SpGridProj, !is.na(SpGridProj@data$ID))   ### SpGridProj[!is.na(SpGridProj@data$Intersects$ID),] 			###

plot(SpGridProj)
plot(Polys, add=T)
plot(localmap, col='darkolivegreen3', add=T)


  Count <- 0
  for(i in 1:length(Polys))
    {
    TempB <- Polys[i,]
    Temp <- over(SpGridProj,TempB)[,1]
    Temp[is.na(Temp)] <- 0
    Temp[Temp > 0] <- 1
    Count <- Count + Temp
    #Prop <- Count/i
    }
  Prop <- Count/length(Polys) ### removed from loop over polys as it only needs to be calculated once
  GridIntersects$inside<-as.numeric(as.character(GridIntersects$ID))
  GridIntersects$Prop <- 0
  GridIntersects$Prop[!is.na(GridIntersects$inside)] <- Prop	#[,1]


  SpGrid <- SpatialPoints(Grid, proj4string = CRS("+proj=longlat + datum=wgs84"))
  SpdfGrid <- SpatialPointsDataFrame(SpGrid, data.frame(Longitude=SpGrid@coords[,1], Latitude=SpGrid@coords[,2]))
  SpdfGrid$Count <- 0
  SpGridVals <- SpatialPixelsDataFrame(SpGrid, data.frame(Values = GridIntersects$Prop))
  SGExtent <- extent(SpdfGrid)
  RT <- raster(SGExtent, as.double(NCol), as.double(NRow))
  WgsRas <- (rasterize(x=SpGridVals, y=RT, field = "Values"))

  plot(WgsRas, asp=1)
  map("world", add=T, fill=T, col="darkolivegreen3")
  projection(WgsRas) <- CRS("+proj=longlat + datum=wgs84")

  SpGridVals <- SpatialPixelsDataFrame(SpGrid, data.frame(Values = GridIntersects$Prop))
  SGExtent <- extent(SpdfGrid)
  RT <- raster(SGExtent, as.double(NCol), as.double(NRow))
  WgsRas <- (rasterize(x=SpGridVals, y=RT, field = "Values"))

  plot(WgsRas, asp=1)
  map("world", add=T, fill=T, col="darkolivegreen3")
  projection(WgsRas) <- CRS("+proj=longlat + datum=wgs84")
  return(WgsRas)
  }





















#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# USE TripGrid to calculate spatial aggregation index
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
### will need interpolation?

library(trip)
#### SET THE BOUNDING BOX
long<-bbox(Trips)[1,]	### 20.360492 is westernmost nest, 44.9 is east of Yemen/Djibouti crossing
lat<-bbox(Trips)[2,]	### 11.5 is Djibouti cut-off for migration, 43.69655 is northern most EGVU nest
boundbox<-matrix(c(long,lat), ncol=2, byrow=F)


### CREATE A GRID AND COUNT NUMBER OF LOCATIONS IN EACH GRID CELL ###
grd<-makeGridTopology(boundbox, cellsize = c(10,10), adjust2longlat = F)			### CREATE THE GRID USING Trips 
extent(grd)

### CREATE A TRIPS OBJECT FOR THE GRID FROM Trips ###
all_trips<-trip(Trips, TORnames=c("DateTime","ID"))			### switch to "DateTime" when using the raw locations
trg <- tripGrid(all_trips, grid=grd,method="pixellate")						### this will provide the number of bird seconds spent in each grid cell
spplot(trg)			## plots the trips with a legend
proj4string(turbSPDF)<-proj4string(EVSP_all)


### CONVERT SPATIAL GRID TO SOMETHING WE CAN PLOT
spdf <- SpatialPixelsDataFrame(points=trg, data=trg@data)
HOTSPOTS<-data.frame(lat=spdf@coords[,2],long=spdf@coords[,1],time=spdf@data$z)
HOTSPOTS$time<-HOTSPOTS$time/(3600*24)								### this converts the seconds into bird days
summary(HOTSPOTS)

HOTSPOTS<-HOTSPOTS[HOTSPOTS$time>10,]

##### CONVERT TO SPATIAL POLYGONS FOR OVERLAY ###
ras<- raster(spdf)		# converts the SpatialPixelDataFrame into a raster
spoldf <- rasterToPolygons(ras, n=4) # converts the raster into quadratic polygons
proj4string(spoldf)<-proj4string(EVSP_all)


### PRODUCE NICE AND SHINY MAP WITH THE MOST IMPORTANT TEMPORARY CONGREGATION SITES ###

#MAP <- get_map(EGVUbox, source="google", zoom=4, color = "bw")		### retrieves a map from Google (requires live internet connection)
MAP <- get_map(location = c(lon = mean(long), lat = mean(lat)), source="google", zoom=4, color = "bw")		### retrieves a map from Google (requires live internet connection)

pdf("EGVU_MIGRATION_HOTSPOTS.pdf", width=12, height=11)
ggmap(MAP)+geom_tile(data=HOTSPOTS, aes(x=long,y=lat, fill = time)) +
	scale_fill_gradient(name = 'N bird days', low="white", high="red", na.value = 'transparent', guide = "colourbar", limits=c(10, 30))+
	theme(axis.ticks = element_blank(),axis.text = element_blank(),axis.title = element_blank())+
	theme(strip.text.y = element_text(size = 20, colour = "black"), strip.text.x = element_text(size = 15, colour = "black"))+
	geom_point(data=turbs, aes(x=Longitude, y=Latitude), pch=16, col='darkolivegreen', size=0.5)
dev.off()



