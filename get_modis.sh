#!/bin/bash

#TODO: to get all MODIS grids around a buffered track, use the dates from before the earliest in the track, and after the latest.

usage()
{
cat << EOF
usage: $0 [OPTIONS]

Downloads MODIS EVI 16 day composites for IBTracs.
Grabs one before image and one after image - on either side of the composite that contains the storm date.
Three images are looked at before and three after - for each, only the image with the least cloud cover is downloaded.


NB: Images are currently set to download from 2002-2010 storm seasons.

OPTIONS:
   -h     Show this message
   -s     name of input storms table in the PostgreSQL database - this should be the IBTracs data from shapefile
   -d     name of PostgreSQL database
   -c     name of CSV file to create
   -o     name of output directory 
EOF
}

while getopts "ho:s:d:c:" OPTION
do
     case $OPTION in
         h)
             usage
             exit 1
             ;;
         o)
             outdir=$OPTARG
             ;;
         s)
             storms=$OPTARG
             ;;
         d)
             db=$OPTARG
             ;;
         c)
             csv=$OPTARG
             ;;
         ?)
             usage
             exit
             ;;
     esac
done

getInfo()
{
tmpfile=/tmp/out.txt

# in the database, select certain fields from the line file
# note that the appropriate line file must already exist - in out example we use one that is for 2002-2010 season storms that intersect forest
psql -d $db -c "select serial_num,iso_time,v,h from $storms;" | grep -vE "\-\-|\([0-9]+ rows\)" > $tmpfile
# maintain the field names as a variable
header=$(sed -n '1p' $tmpfile); sed -i '1d' $tmpfile
# get the list of MODIS sinosoidal rows	
awk -F\| '{print $3}' $tmpfile > /tmp/v.txt
# get the list of MODIS sinosoidal columns
awk -F\| '{print $4}' $tmpfile > /tmp/h.txt
# add a leading '0' in front of row and column names below 10 - these are used by the FTP
sed -i 's:[ \t]::g;s:\(\b[0-9]\{1\}\b\):0\1:g' /tmp/v.txt
sed -i 's:[ \t]::g;s:\(\b[0-9]\{1\}\b\):0\1:g' /tmp/h.txt
# put iso times in their own file
awk -F\| '{print $2}' $tmpfile > /tmp/iso_time.txt
# remove units of time below a day from the list of iso times
sed -i 's:[ \t]$::g;s: [0-9:]\+$::g;s:[ \t]::g;s:[-]:.:g' /tmp/iso_time.txt
# clean tmp file
sed -i 's:[ \t]::g;s:^\([0-9A-Z]\+[^|]\).*:\1:g' $tmpfile
# join tmp file with cleaned iso times, and MODIS rows and columns for each storm
paste -d, $tmpfile /tmp/iso_time.txt /tmp/v.txt /tmp/h.txt > $csv
# remove the last line, which is just commas
sed -i '$d' $csv
}

getFolders()
{
# get list of all folders for Terra 16 day composites
tmpMOLT=/tmp/MOLT.txt
curl -S ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/ | awk '{print $NF}' | sed -n 's:[0-9]\{4\}[.][0-9]\{2\}[.][0-9]\{2\}:&:p' > $tmpMOLT
}

getRanges()
{
# get beginning and ending ranges for 16 day composites as seconds
rm /tmp/MOLT.ranges 2>/dev/null
while read line
do 
	# for every folder by date, find the name of the last 16 day composite
	xmladdress=$(curl -S ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/$line/|awk '{print $NF}'|sed '/hdf$/d'|sed '$!d')
	# download the metadata
	curl -S ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/$line/$xmladdress > /tmp/MOLT.xml
	# find the end date of the composite
	xmlEndDate=$(grep -E "<RangeEndingDate>" /tmp/MOLT.xml | grep -oE "[0-9-]+")
	# calculate this as seconds since 1970-01-01
	endSeconds=$(date -d $xmlEndDate +%s)
	# find the begin date of the composite
	xmlBeginDate=$(grep -E "<RangeBeginningDate>" /tmp/MOLT.xml | grep -oE "[0-9-]+")
	# calculate this as seconds since 1970-01-01
	beginSeconds=$(date -d $xmlBeginDate +%s)
	# print the folder name and the date ranges in seconds to a file
	echo $line $beginSeconds $endSeconds >> /tmp/MOLT.ranges
done < $tmpMOLT
}

getURL()
{

# sort unique on getRanges outputs
sort -u -s -t, -k1 $csv > /tmp/sortUniq.csv

rm -r $outdir/getMODISurl 2>/dev/null
mkdir -p $outdir/getMODISurl

while read line
do 
	# get the date of the storm
	stormDate=$(echo $(echo $line | awk -F, '{print $2}') | sed 's:[.]:-:g')
	# get the date of the storm in seconds since 1970-01-01	
	stormSeconds=$(date -d $stormDate +%s)
	# get a list of 16 day composites the storm falls under - might be more than one
	preImageDate=$(awk "{if ($stormSeconds >= \$2 && $stormSeconds <= \$3) print \$1}" /tmp/MOLT.ranges)
	# get just the earliest 16 day composite the storm falls under - may want to change this
	imageDate=$(echo $preImageDate | awk '{print $1}')
	# get the three dates before the composite the storm falls under
	datesBefore=$(grep -E -B 3 "$imageDate" $tmpMOLT | grep -vE "$imageDate")
	# get the three dates after the composite the storm falls under
	datesAfter=$(grep -E -A 3 "$imageDate" $tmpMOLT | grep -vE "$imageDate")
	# get the row number for MODIS sinosoidal tiles for the storm
	v=$(echo $line | awk -F, '{print $3}')
	# get the column number for MODIS sinosoidal tiles for the storm
	h=$(echo $line | awk -F, '{print $4}')
	# of the last three composites before the composite the storm falls under, find the one with the least cloud cover
	getBefore=$(for i in $datesBefore; do cloudCover=$(wget -qO- ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/$i/*.h${h}v${v}*.hdf.xml | grep -E "<QAPercentCloudCover>" | uniq | grep -oE "[0-9]+") echo $i $cloudCover; done | sort -rn | sed q | awk '{print $1}')
	# of the last three composites after the composite the storm falls under, find the one with the least cloud cover
	getAfter=$(for i in $datesAfter; do cloudCover=$(wget -qO- ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/$i/*.h${h}v${v}*.hdf.xml | grep -E "<QAPercentCloudCover>" | uniq | grep -oE "[0-9]+"); echo $i $cloudCover; done | sort -rn | sed q | awk '{print $1}')
	serial_num=$(echo $line | awk -F, '{print $1}')
	iso_time=$(echo $line | awk -F, '{print $2}' | sed 's:[.]::g')
	echo getBefore is $getBefore getAfter is $getAfter
	# write the appropriate before composite url to file
	echo "ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/$getBefore/*.h${h}v${v}*.hdf" >> $outdir/getMODISurl/${serial_num}_v${v}h${h}_${iso_time}.txt
	# write the appropriate after composite url to file
	echo "ftp://e4ftl01.cr.usgs.gov/MODIS_Composites/MOLT/MOD13Q1.005/$getAfter/*.h${h}v${v}*.hdf" >> $outdir/getMODISurl/${serial_num}_v${v}h${h}_${iso_time}.txt
done < /tmp/sortUniq.csv
}

getStormName()
{

# re-organize the txt files w/ urls to be by storm name
cd $outdir/getMODISurl

for i in *.txt
do 
	serial_num=$(echo $i | grep -oE "^[^_]*" | sed "s:^:':g;s:$:':g")
	storm_name=$(psql -d modis -c "select distinct(name) from select_ibtracs where serial_num = $serial_num;" | sed 1,2d | sed 2d | sed 's:[ \t]\+:_:g')
	mkdir ${storm_name}_$(basename $i .txt)
	mv $i ${storm_name}_$(basename $i .txt)
done

}

getMODIS()
{

# get MODIS hdf images and xml metadata
cd $outdir/getMODISurl

for i in *
do 
	cd $i
	while read line
	do 
		wget -c ${line}.xml
		wget -c ${line}
	done < $(ls *.txt)
	cd - 1>/dev/null
done

}

#getInfo
#getFolders
#getRanges
#getURL
getStormName
#getMODIS

exit 0
