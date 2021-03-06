suppressPackageStartupMessages(library(data.table, quietly=TRUE))
suppressPackageStartupMessages(library(dplyr, quietly=TRUE)) 
suppressPackageStartupMessages(library(plyr, quietly=TRUE))
suppressPackageStartupMessages(library(xgboost, quietly=TRUE))

###################  Select candidates  ###################################
train <- fread("../input/train.csv", colClasses=list(character="place_id"))
Ttrain <- max(train$time)

X1 <- 100
Y1 <- 200
temp<-train[,.(place_id)]
temp[,"new.x1"]<-as.integer(floor(train$x/(10+1E-10)*X1))
temp[,"new.y1"]<-as.integer(floor(train$y/(10+1E-10)*Y1))

temp<-ddply(temp,.(new.x1,new.y1,place_id), nrow)
temp<-temp[with(temp,order(new.x1,new.y1,-V1)),]

tp<-data.frame()
for(i in 0:max(temp$new.x1)){
  for(j in 0:max(temp$new.y1)){
    tm<-temp[temp$new.x1==i & temp$new.y1==j & temp$V1>=2,]
    tm$rank<-seq.int(nrow(tm))
    tp<-rbind(tp,tm)
  }
  cat("x loop at i= ",i,"\n")
}
Ncandidate<-max(tp$rank)
candidate <-filter(tp,rank==1)[, 1:3]
for(i in 2:Ncandidate) {
  candidate <- merge(candidate, filter(tp, rank==i)[, 1:3], by=c("new.x1","new.y1"), all.x=TRUE, suffixes=c("",paste0("_",i)))
}
colnames(candidate)[3:ncol(candidate)] <- paste0("candidate_", 1:Ncandidate)
rm(temp)
####################  Features  ##################################################

X2<-1200
temp <- train[, .(place_id, accuracy, x, new.x2 = as.integer(floor(x/(10+1E-10)*X2)))]
temp <- temp[, .(count1=sum(x/sqrt(2*pi*accuracy^2)*exp(-(x*x)/accuracy^2/2)), count=.N), by=c("place_id","new.x2")]
Dx <- temp[, .(place_id, new.x2, count.x = count1/count)]
rm(temp)

Y2<-4000
temp <- train[, .(place_id, accuracy, y, new.y2 = as.integer(floor(y/(10+1E-10)*Y2)))]
temp <- temp[, .(count1=sum(y/sqrt(2*pi*accuracy^2)*exp(-(y*y)/accuracy^2/2)), count=.N), by=c("place_id","new.y2")]
Dy <- temp[, .(place_id, new.y2, count.y = count1/count)]
rm(temp)

num.d<-40
temp <- train[, .(place_id, accuracy, new.d = as.integer(floor((time%%(60*24))/(60*24+1E-10)*num.d)))]
temp <- temp[, .(count1=sum(new.d/sqrt(2*pi*accuracy^2)*exp(-(new.d*new.d)/accuracy^2/2)), count=.N), by=c("place_id","new.d")]
Dday <- temp[, .(place_id, new.d, count.d = count1/count)]
rm(temp)

num.w <- 7*3
temp <- train[, .(place_id, accuracy, new.w = as.integer(floor((time%%(60*24*7))/(60*24*7+1E-10)*num.w)))]
temp <- temp[, .(count1 = sum(new.w/sqrt(2*pi*accuracy^2)*exp(-(new.w*new.w)/accuracy^2/2)), count=.N), by=c("place_id","new.w")]
Dweek <- temp[, .(place_id, new.w, count.w = count1/count)]
rm(temp)

num.a<-70
n.w<-60*24*7
temp <- train[, .(place_id, time, new.a = as.integer(floor(log10(accuracy)/3*num.a)))]
temp<-temp[,.(count1 = sum(.5 + 0.5*cos(2*pi*(time/n.w+5)/20), count =.N), count=.N), by=c("place_id","new.a")] 
Daccurac<-temp[, .(place_id, new.a, count.a=count1/count)]
rm(temp)

###################################### Xgboost  ##############################

test <- fread("../input/test.csv")
Ttest <- max(test$time)

Tpredict <- 24*60*7*2
ID<-data.table(train[!duplicated(train$place_id),.(place_id)])

for(i in 1:(Ttrain/Tpredict)) {
   temp<-train[time>Ttrain-Tpredict*i & time<=Ttrain-Tpredict*(i-1), .N, by="place_id"]
   ID <- merge(ID, temp, by="place_id", all.x=TRUE)
   colnames(ID)[ncol(ID)] <- paste0("ID_", as.integer(Ttrain-Tpredict*i), "-", as.integer(Ttrain-Tpredict*(i-1)))
}

ID[is.na(ID)] <- 0
pr.prob<-ID[,1, with=F]
params <- list("eta"=0.1, "max_depth"=6, "min_child_weight"=100, "objective"="reg:linear", "eval_metric"="rmse")
for(i in 1:ceiling((Ttest-Ttrain)/Tpredict)) {
  
  cat(paste0("    substep: ", i, "/", ceiling((Ttest-Ttrain)/Tpredict),"\n"))
  
  trainX <- ID[, (i+2):ncol(ID), with=FALSE]
  trainY <- ID[[2]][apply(trainX, 1, sum) > 0]
  trainX <- trainX[apply(trainX, 1, sum) > 0]
  testX <- ID[, 2:(ncol(ID)-i), with=FALSE]
  
  trainX <- as.matrix(trainX)*1.0
  testX <- as.matrix(testX)*1.0
  
  if(i == 1) {
    nrounds <- 100
  } else if(i == 2) {
    nrounds <- 30
  } else {
    nrounds <- 10
  }
  
  set.seed(0)
  model.xgb <- xgb.train(param=params, data=xgb.DMatrix(trainX, label=trainY), nrounds=nrounds)
  
  temp <- predict(model.xgb, testX)
  temp[temp<0] <- 0
  temp <- temp/sum(temp)
  pr.prob <- cbind(pr.prob, temp)
  colnames(pr.prob)[ncol(pr.prob)] <- paste0("pr_", as.integer(Ttrain+Tpredict*(i-1)), "-", as.integer(Ttrain+Tpredict*i))
  
}
rm(ID)
rm(trainX)
rm(trainY)
rm(testX)
rm(temp)
rm(train)
########################  Prediction ###################################################

Tstep <- 1000000
result <- data.table()

for(i in 1:ceiling(nrow(test)/Tstep)) {
 
cat(paste0(" Final run test data   substep: ", i, "/", ceiling(nrow(test)/Tstep),"\n"))
data.batch <- test[((i-1)*Tstep+1):min(i*Tstep,nrow(test)), ] %>%
    mutate(new.x1 = as.integer(floor(x/(10+1E-10)*X1)),
           new.y1 = as.integer(floor(y/(10+1E-10)*Y1)),
           new.x2 = as.integer(floor((x/(10+1E-10)*X2))),
           new.y2 = as.integer(floor((y/(10+1E-10)*Y2))),
           new.d  = as.integer(floor((time%%(60*24))/(60*24+1E-10)*num.d)),
           new.w  = as.integer(floor((time%%(60*24*7))/(60*24*7+1E-10)*num.w)),
           new.a  = as.integer(floor(log10(accuracy)/3*num.a)))
data.batch$new.a[data.batch$new.a>=num.a] <- num.a-1
data.batch <- merge(data.batch, candidate, by=c("new.x1", "new.y1")) %>% arrange(row_id)
pr.table <- data.batch[, "row_id", with=FALSE]

for(j in 1:(ncol(candidate)-2)) {
    temp <- data.batch[, c("row_id","time","new.x2","new.y2","new.d","new.w","new.a",paste0("candidate_",j)), with=FALSE]
    temp <- merge(temp, Dx,by.x=c(paste0("candidate_",j),"new.x2"),by.y=c("place_id","new.x2"))
    temp <- merge(temp, Dy,by.x=c(paste0("candidate_",j),"new.y2"),by.y=c("place_id","new.y2"))
    temp <- merge(temp, Dday,by.x=c(paste0("candidate_",j),"new.d"),by.y=c("place_id","new.d"), all.x=TRUE)
    temp <- merge(temp, Dweek,by.x=c(paste0("candidate_",j),"new.w"),by.y=c("place_id","new.w"), all.x=TRUE)
    temp <- merge(temp, Daccurac,by.x=c(paste0("candidate_",j),"new.a"),by.y=c("place_id","new.a"), all.x=TRUE)
    temp <- merge(temp, pr.prob,by.x=paste0("candidate_",j),by.y="place_id")
    
    pr.x <- temp$count.x
    pr.y <- temp$count.y
    
    temp$count.d[is.na(temp$count.d)] <- 0
    temp$count.d <- temp$count.d + 0.1
    pr.time_of_day <- temp$count.d 
    
    temp$count.w[is.na(temp$count.w)] <- 0
    temp$count.w <- temp$count.w + 1
    pr.day_of_week <- temp$count.w 
    
    temp$count.a[is.na(temp$count.a)] <- 0
    temp$count.a <- temp$count.a + 0.1
    pr.accuracy <- temp$count.a 

    temp$pr.place <- NA
    for(k in 1:(ncol(pr.prob)-1)) {
      temp$pr.place <- ifelse(is.na(temp$pr.place) & (temp$time <= Ttrain+Tpredict*k), temp[[colnames(pr.prob)[k+1]]], temp$pr.place)
    }
    temp$pr.place[temp$pr.place < 4E-6] <- 4E-6
    
    temp$log.pr <- log(temp$pr.place) + log(pr.x) + log(pr.y) + log(pr.time_of_day) + log(pr.day_of_week) + log(pr.accuracy)
    temp <- temp[, .(row_id, log.pr)] %>% arrange(row_id)
    pr.table <- merge(pr.table, temp, by="row_id", all.x=TRUE)
    colnames(pr.table)[ncol(pr.table)] <- paste0("log.pr_",j)
  }
 
  result.batch <- data.batch[, .(row_id)]  
  
  temp<-apply(pr.table[, 2:ncol(pr.table), with=FALSE],1,function(x) order(x, decreasing = T)[1])
  for(j in 1:(ncol(candidate)-2)) {
    result.batch[temp==j, "p1"] <- data.batch[temp==j, ][[paste0("candidate_",j)]]
  } 
  temp<- apply(pr.table[, 2:ncol(pr.table), with=FALSE],1,function(x) order(x, decreasing = T)[2])
  for(j in 1:(ncol(candidate)-2)) {
    result.batch[temp==j, "p2"] <- data.batch[temp==j, ][[paste0("candidate_",j)]]
  } 
  temp<-  apply(pr.table[, 2:ncol(pr.table), with=FALSE],1,function(x) order(x, decreasing = T)[3])
  for(j in 1:(ncol(candidate)-2)) {
    result.batch[temp==j, "p3"] <- data.batch[temp==j, ][[paste0("candidate_",j)]]
  } 
  rm(temp)
  result <- rbind(result, result.batch) 
}

############################## Submission ################################

result$place_id <- paste(result$p1, result$p2, result$p3)
result <- merge(test[, .(row_id)], result[, .(row_id, place_id)], by="row_id", all.x=TRUE)
write.csv(result, "Submission.csv", row.names=FALSE, quote=FALSE)
