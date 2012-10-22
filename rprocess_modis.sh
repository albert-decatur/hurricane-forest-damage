#!/bin/bash
# r.process_modis.sh
# working with esteban rossi on hurricane forest damage worldwide since 2002 using modis - work being done in 2012

#
#Find change in EVI for buffered storm tracks given MODIS 16 day EVI composites
#and a pgSQL database with storm tracks.
#Performs the following - grab just EVI and reliability (includes clouds), 
#buffer storm track by serial number, reproject EVI and reliability,
#clip reprojected EVI and reliability to buffered storm track, and HOPEFULLY clip precisely to buffered storm track, mask out clouds, rescale from 0 - 100, map algebra on earlier EVI minus later EVI.
#
#NB: will play with buffer distances in pgsql / make user variable, reliability mask has to be 0 for BOTH reliability files!

#%Module
#%  description: #Find change in EVI for buffered storm tracks given MODIS 16 day EVI composites
#%End
#%Option
#% key: inputDB
#% type: string
#% description: database that contains table with ibtracs
#% required : yes
#%End
#%Option
#% key: inputTable
#% type: string
#% description: table in inputDB taht contains ibtracs
#% required : yes
#%End

if [ -z "$GISBASE" ] ; then
    echo "You must be in GRASS GIS to run this program." 1>&2
    exit 1
fi

if [ "$1" != "@ARGS_PARSED@" ] ; then
  exec g.parser "$0" "$@"
fi

# NB: will remove everything in current mapset
while [ -n "$(g.mlist type=rast type=vect)" ] ; do
        g.mremove -f rast="*" vect="*"
done

# clear data from pervious run
rm out* buffer_* reliability* EVI* 2>/dev/null

acquisitionDate()
{
rm /tmp/acquisitionDate.txt 2>/dev/null

for i in *.hdf
do
	# get info on acquisition date - year and julian day
	acquisitionDate=$(echo $i | sed 's:MOD13Q1[.]A::g' | grep -oE "^[^.]+")
	echo $acquisitionDate $i >> /tmp/acquisitionDate.txt
done
}

grabTrac()
{
# make shp from the storm based on serial number
serial_num=$(pwd | sed 's:_: :g' | awk '{print $3}')
pgSerial_num=$(echo "'"${serial_num}"'")
pgsql2shp -f buffer_${serial_num}.shp $GIS_OPT_INPUTDB "select serial_num,st_buffer(st_union(the_geom),1) as the_geom from $GIS_OPT_INPUTTABLE where serial_num = $pgSerial_num group by serial_num;"
}

geoprocess()
{
# for i in "list of MODIS files sorted by date of acquisition, first to last"
# get count to determine the order of map algebra, eg A - B
count=1
for i in $(sort -n -k 1 /tmp/acquisitionDate.txt | awk '{print $2}')
do 
	r.mask -r
	# get the name of the EVI subdataset
	EVI_layer=$(gdalinfo $i | grep "SUBDATASET_2_NAME=" | sed 's:SUBDATASET_2_NAME=::g' | sed 's:^[ \t]\+::g')
	# get the name of the reliability subdataset
	reliability_layer=$(gdalinfo $i | grep "SUBDATASET_12_NAME=" | sed 's:SUBDATASET_12_NAME=::g' | sed 's:^[ \t]\+::g')
	# quote these names for gdal_translate
	quoted_EVI=$(echo "\"$EVI_layer\"")
	quoted_reliability=$(echo "\"$reliability_layer\"")
	# extract just the subdatasets
	sh -c "gdal_translate $quoted_EVI outEVI_1.tif"
	sh -c "gdal_translate $quoted_reliability outREL_1.tif"
	gdalwarp -t_srs EPSG:4326 outEVI_1.tif outEVI_2.tif
	gdalwarp -t_srs EPSG:4326 outREL_1.tif outREL_2.tif
	GDALextent=$(gdalinfo outEVI_2.tif | grep -E "Upper Left|Lower Left|Upper Right|Lower Right" | sed 's:( :(:g' | awk '{print $3,$4}' | sed 's:(::g;s:)::g;s:,::g' | sed '1d' | sed '3d' | tr '\n' ' ')
	ogr2ogr -clipsrc $GDALextent out1.shp buffer_${serial_num}.shp
	OGRextent=$(ogrinfo -ro -so -al out1.shp | grep Extent | grep -oE "[0-9.-]+" | sed '3d' | tr '\n' ' '| awk '{print $1 " " $4 " " $3 " " $2}')
	gdal_translate -projwin $OGRextent outEVI_2.tif EVI_$(basename $i .hdf).tif
	gdal_translate -projwin $OGRextent outREL_2.tif REL_$(basename $i .hdf).tif
	rm out*
	r.in.gdal -o -e --overwrite input=EVI_$(basename $i .hdf).tif output=EVI_$(basename $i .hdf)
	r.in.gdal -o -e --overwrite input=REL_$(basename $i .hdf).tif output=REL_${count}
	g.region -a rast=EVI_$(basename $i .hdf)
	r.rescale input=EVI_$(basename $i .hdf) from=2000,10000 output=scaleEVI_${count} to=0,100	
	count=$(($count+1))
done
}

mapAlgebra()
{
r.mapcalc diffEVI_${serial_num}="scaleEVI_1 - scaleEVI_2"
r.mapcalc mask="if(REL_1==0 || REL_1==1 && REL_2==0 || REL_2==1,0,1)"
r.mask input=mask maskcats=0
r.out.gdal input=diffEVI_${serial_num} output=diffEVI_${serial_num}.tif
}

# execute functions
acquisitionDate
grabTrac
geoprocess
mapAlgebra

exit 0
