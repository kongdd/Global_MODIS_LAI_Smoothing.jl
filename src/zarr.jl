using YAXArrays
using Zarr
import Zarr: ConcurrentRead, NoCompressor, BloscCompressor, ZlibCompressor
using DiskArrays: GridChunks
using JSON
using Terra
using Rasters

# chunks = GridChunks(sizes[1], chunksize)
Zarr.store_read_strategy(::DirectoryStore) = ConcurrentRead(Zarr.concurrent_io_tasks[])
## 采用Zarr保存数据，免去了数据拼接的烦恼

Base.names(ds::YAXArrays.Dataset) = string.(collect(keys(ds.cubes)))
Base.getindex(ds::YAXArrays.Dataset, i) = ds[names(ds)[i]]
chunksize(ds::YAXArrays.Dataset) = chunksize(ds[1])
chunksize(cube) = Cubes.cubechunks(cube)
GridChunks(z::ZArray) = GridChunks(size(z), chunksize(z))

zarr_rm(p) = rm(p, recursive=true, force=true)

## DirectoryStore
function zarr_group(s::String; overwrite=false, mode="w", kw...)
  if overwrite && isdir(s)
    rm(s, recursive=true, force=true)
  end
  isdir(s) ? zopen(s, mode) : zgroup(s; kw...)
end


"""
    geo_zcreate(p, varname,
        lon, lat, band; chunksize, datatype=Float32)

创建一个geozarr，它可以直接塞给`YAXArrays.open_dataset`

# Return
- `task`: 用于记录哪些chunks运行成功了，运行成功的部分则跳过
- `bbox`: `[xmin, ymin, xmax, ymax]`，仅用bbox也可反推`z`的位置
"""
function geo_zcreate(p::String, varname::String,
  lon::AbstractVector, lat::AbstractVector, band; chunk_size, datatype=Float32, create_dims=false)

  compressor = BloscCompressor(cname="zstd", shuffle=0)
  g = zarr_group(p)
  dims = (length(lon), length(lat), length(band))

  chunk_size = (chunk_size[1:2]..., length(band)) # 最后一维是全部
  chunks = GridChunks(dims, chunk_size)
  tasks = falses(length(chunks))

  name_t = "band"
  isa(band, Band) && (name_t = "Band")
  isa(band, Ti) && (name_t = "time")

  attr_x = Dict("_ARRAY_DIMENSIONS" => ["lon"], "_ARRAY_OFFSET" => 0)
  attr_y = Dict("_ARRAY_DIMENSIONS" => ["lat"], "_ARRAY_OFFSET" => 0)
  attr_t = Dict("_ARRAY_DIMENSIONS" => [name_t], "_ARRAY_OFFSET" => 0)
  attr_z = Dict("_ARRAY_DIMENSIONS" => [name_t, "lat", "lon"],
    "bbox" => bbox2vec(st_bbox(lon, lat)), "task" => tasks)

  if create_dims
    if !isdir("$p/lon")
      x = zcreate(datatype, g, "lon", length(lon); attrs=attr_x)
      x[:] .= lon
    end

    if !isdir("$p/lat")
      y = zcreate(datatype, g, "lat", length(lat); attrs=attr_y)
      y[:] .= lat
    end
  end

  if !isdir("$p/$name_t")
    t = zcreate(eltype(band), g, name_t, length(band); attrs=attr_t)
    t[:] .= band.val
  end

  z = zcreate(datatype, g, varname, dims...; chunks=chunk_size, compressor, attrs=attr_z)
  z
end


function geo_zcreate(p::String, varname::String,
  b::Terra.bbox, cellsize, band; kw...)

  lon, lat = bbox2dims(b; cellsize)
  geo_zcreate(p, varname, lon, lat, band; kw...)
end

# true : 运行结束
# false: 未结束
chunk_task_finished(z::ZArray, ichunk) = z.attrs["task"][ichunk]

function chunk_task_finished!(z::ZArray, ichunk, value=true)
  z.attrs["task"][ichunk] = value
  f = "$(z.storage.folder)/$(z.path)/.zattrs"
  open(f, "w") do fid
    JSON.print(fid, z.attrs)
  end
end

Terra.st_bbox(z::ZArray) = Terra.bbox(z.attrs["bbox"]...)
Terra.st_bbox(zs::Vector{<:ZArray}) = st_bbox(st_bbox.(zs))

function Rasters.resample(zs::Vector{<:ZArray}; fact=10, missingval=0)
  res = Vector{Raster}(undef, length(zs))
  nd = ndims(zs[1])
  cols = repeat([:], nd - 2) # all bands

  @par for i = eachindex(zs)
    println("running $i")
    z = zs[i]
    dat = z[1:fact:end, 1:fact:end, cols...]
    b = st_bbox(z)
    res[i] = Raster(dat, b)
  end
  st_mosaic(res; missingval)
end
