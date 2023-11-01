using Terra
using Zarr
using Shapefile
using YAXArrays


Terra.st_bbox(ds::YAXArrays.Dataset) = st_bbox.(get_zarr(ds)) # multiple

function get_zarr(ds::YAXArrays.Dataset)
  vars = names(ds)
  zs = map(var -> ds[var].data, vars)
  zs
end

st_dims(x::Union{Missing,Shapefile.Point}) = x.x, x.y

function st_dims(xs::Vector{T}) where {T<:Union{Missing,Shapefile.Point}}
  points = st_dims.(xs)
  x = [p[1] for p in points]
  y = [p[2] for p in points]
  x, y
end

bbox2lims(b::bbox) = ((b.xmin, b.xmax), (b.ymin, b.ymax))

Terra.st_bbox(z::ZArray) = Terra.bbox(z.attrs["bbox"]...)
Terra.st_bbox(zs::Vector{<:ZArray}) = st_bbox(st_bbox.(zs))

function st_dims(r::Raster)
  x = r.dims[1].val.data
  y = r.dims[2].val.data
  x, y
end

function slice2(x::AbstractArray, i, j)
  cols = repeat([:], ndims(x) - 2)
  @views x[i, j, cols...]
end

function resample2(r::AbstractArray; fact=10, deepcopy=false)
  cols = repeat([:], ndims(r) - 2)

  if deepcopy
    r[1:fact:end, 1:fact:end, cols...]
  else
    @views r[1:fact:end, 1:fact:end, cols...]
  end
end

# for Raster
st_resample(x::AbstractArray; fact=10) = resample2(x; fact)

function st_resample(z::ZArray; fact=10, missingval=0)
  dat = resample2(z; fact)
  Raster(dat, st_bbox(z); missingval)
end

function st_resample(zs::Vector{<:ZArray}; fact=10, missingval=0)
  res = Vector{Raster}(undef, length(zs))
  @par for i = eachindex(zs)
    println("running $i")
    z = zs[i]
    dat = st_resample(z; fact)
    b = st_bbox(z)
    res[i] = Raster(dat, b)
  end
  st_mosaic(res; missingval)
end

## 判断哪个grid被选择了
in_bbox(b::bbox, (lon, lat)) = (b.xmin < lon < b.xmax) && (b.ymin < lat < b.ymax)

in_bbox(bs::Vector{bbox}, (lon, lat)) = [in_bbox(b, (lon, lat)) for b in bs]

function select_grid(ds, (lon, lat))
  zs = get_zarr(ds)
  bs = st_bbox.(zs)
  inds = in_bbox(bs, (lon, lat)) |> findall
  !isempty(inds) ? names(ds)[inds[1]] : nothing
end

function st_location((x, y)::Tuple{Real,Real};
  b::bbox, cellx::Real, celly::Real, nx::Int, ny::Int)

  i = (x - b.xmin) / cellx
  if celly > 0
    j = (y - b.ymin) / celly
  else
    j = (b.ymax - y) / abs(celly)
  end
  i = floor(Int, i)
  j = floor(Int, j)

  if (i < 1 || i > nx) || (j < 1 || j > ny)
    nothing
  else
    i, j
  end
end

function st_location(r::Raster, points::Vector{Tuple{T,T}}) where {T<:Real}
  b = st_bbox(r)
  nx, ny = size(r)[1:2]
  cellx, celly = st_cellsize(r)
  inds, locs = st_location.(points; b, cellx, celly, nx, ny) |> rm_empty
  inds, locs
end

function st_extract(ra::Raster, points::Vector{Tuple{T,T}}; combine=hcat) where {T<:Real}
  inds, locs = st_location(ra, points)
  cols = repeat([:], ndims(ra) - 2)
  lst = [ra.data[i, j, cols...] for (i, j) in locs]
  inds, combine(lst...) #cbind(lst...)
end