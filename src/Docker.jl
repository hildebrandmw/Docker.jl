module Docker

export Container

# stdlib requirements
using Sockets

# package requirements
using HTTP
using JSON

const SRCDIR = @__DIR__
const PKGDIR = dirname(SRCDIR)
const DEPDIR = joinpath(PKGDIR, "deps")

# Extend the "getconnection" function in HTTP to support unix sockets. This allows us to
# directly communicate with the local docker daemon.
function HTTP.ConnectionPool.getconnection(
        ::Type{Sockets.PipeEndpoint},
        host::AbstractString,
        port::AbstractString;
        unix_socket = "",
        kw...
    )::Sockets.PipeEndpoint

    return Sockets.connect(unix_socket)
end

daemon() = "/var/run/docker.sock"

############################################################################################

_query(nt) = Tuple(string(k) => v for (k,v) in pairs(nt))

macro query(ex)
    if ex.head != :tuple
        ex = Expr(:tuple, ex)
    end
    return esc(:(Docker._query($ex)) )
end

# Type for eaily working with containers
mutable struct Container
    id::String
    params::Dict{String,Any}
end

Container(id::String) = Container(id, Dict{String,Any}())
Container(json::Dict) = Container(getid(json), json)

function Base.show(io::IO, c::Container)
    println(io, "Docker Container")
    println(io, "   ID: $(getid(c))")
    # Display some extra information.
    for k in ("Image", "Command", "State")
        if haskey(c.params, k)
            println(io, "   $k: $(c.params[k])")
        end
    end
end

getid(x::String) = x
getid(x::Dict) = x["Id"]
getid(x::Container) = x.id

#default_endpoint() = (host = "localhost", port = _port())
docker_uri(;path = nothing, kw...) = HTTP.URI(;
    scheme = "http",
    path = path,
    host = "localhost",
    kw...
)

docker_headers() = Dict("Content-Type" => "application/json")
parse(data) = JSON.parse(String(data))

test(path) = HTTP.request("GET", docker_uri(path = path), socket_type = Sockets.PipeEndpoint, unix_socket = daemon())

const localkw = (socket_type = Sockets.PipeEndpoint, unix_socket = daemon())


function list_images(;all = false)
    uri = docker_uri(path = "/images/json", query = @query(all=all))
    resp = HTTP.get(uri; localkw...)
    return parse(resp.body)
end


function pull_image(name)
    uri = docker_uri(path = "/images/create", query = @query(fromImage=name)) 
    resp = HTTP.post(uri; localkw...)
    return resp
end

function remove_image(name; force = false)
    uri = docker_uri(path = "/images/$name", query = @query(force=force))
    resp = HTTP.delete(uri; localkw...)
    return resp
end


function create_container(
        image;
        #endpoint = default_endpoint(),
        cmd          = ``,
        user         = "", 
        entryPoint   = "",
        tty          = true,
        attachStdin  = false,
        openStdin    = false,
        attachStdout = true,
        attachStderr = true,
        binds        = [],
        memory       = 0,
        memoryswap   = nothing,
        cpuSets      = "",
        cpuMems      = "",
        volumeDriver = "",
        portBindings = ["",""], # [ContainerPort,HostPort]
        ports        = [],
        pwd          = "",
        env          = [],
        privileged   = false,
        capadd       = [],
    )

    params = Dict(
        "Image" => image,
        "Tty" => tty,
        "Env" => env,
        "AttachStdin"   => attachStdin,
        "OpenStdin"     => openStdin,
        "AttachStdout"  => attachStdout,
        "AttachStderr"  => attachStderr,
        "ExposedPorts"  => Dict([Pair("$(string(p, base=10))/tcp", Dict()) for p in ports]),
        "HostConfig"    => Dict(
            "Memory"       => memory,
            "CpusetCpus"   => cpuSets,
            "CpusetMems"   => cpuMems,
            "VolumeDriver" => volumeDriver,
            "PortBindings" => Dict(
                string(portBindings[1],"/tcp") => [
                    Dict("HostPort" => string(portBindings[2]))
                ]
            ),
            "Binds" => binds,
            "CapAdd" => capadd,
        )
    )

    if privileged
        params["HostConfig"]["SecurityOpt"] = ["seccomp=unconfined"]
    end

    if !isempty(user)
        params["User"] = user
    end

    if !isempty(entryPoint)
        params["Entrypoint"] = entryPoint
    end

    if !isempty(cmd.exec)
        params["Cmd"] = collect(cmd.exec)
    end

    if !isempty(pwd)
        params["WorkingDir"] = pwd
    end

    if memoryswap !== nothing
        params["HostConfig"]["MemorySwap"] = memoryswap
    end

    uri = docker_uri(path = "/containers/create")
    resp =  HTTP.post(uri, docker_headers(), JSON.json(params); localkw...)
    # Create a container out of the response
    return Container(parse(resp.body)) 
end

macro defcontainerfunc(func, method, endpoint)
    # Check method type. If it is a get, we want to return the parsed response. Otherwise,
    # return the container object support function chaining.
    if method == :GET 
        retbody = :(parse(resp.body))
    else
        retbody = :(container)
    end

    return quote
        function $(esc(func))(container::Container)
            id = getid(container)
            uri = docker_uri(path = joinpath("/containers", id, $(string(endpoint))))
            resp = HTTP.request($(string(method)), uri; localkw...)
            return $retbody
        end
    end
end

@defcontainerfunc inspect   GET  json
@defcontainerfunc start     POST start
@defcontainerfunc restart   POST restart
@defcontainerfunc stop      POST stop
@defcontainerfunc pause     POST pause
@defcontainerfunc unpause   POST unpause
@defcontainerfunc Base.kill POST kill
@defcontainerfunc processes GET  top

function remove(container; force = false)
    id = getid(container)
    uri = docker_uri(path = "/containers/$(id)", query = @query(force=force))
    resp = HTTP.delete(uri; localkw...)
end


function list_containers(;all = false, filters = Dict{String,Any}())
    path = "/containers/json"
    query = @query (all=all, filters=json(filters))

    uri = docker_uri(path = path, query = query)

    resp = HTTP.get(uri; localkw...)
    return Container.(parse(resp.body))
end

function log(container; since = 0, tail = "all")
    id = getid(container)
    path = "/containers/$id/logs"
    query = @query (stdout=true, since=since, tail=tail)
    uri = docker_uri(path = path, query = query)
    headers = Dict("Content-Type"=>"plain/text")
    resp = HTTP.get(uri, headers; localkw...)
    return String(resp.body)
end

function stats(container)
    id = getid(container)
    path = "/containers/$id/stats"
    # TODO: right now, we can't support upgrading to a stream, so we must manage
    # streaming behavior on the client side.
    query = @query(stream = false)
    stats = Dict{String,Any}[]
    uri = docker_uri(path = path, query = query)
    resp = HTTP.get(uri; localkw...)
    return parse(resp.body)
end

function attach(container; stdin = stdin, stdout = stdout, stderr = stderr)
    id = getid(container)
    try
        run(`docker attach $id --detach-keys="q"`)
    finally
        print("\n")
        @info "Detached from $id"
        return 
    end
end

function cleanse!()
    uri = docker_uri(path = "/containers/json?all=true")
    resp = HTTP.get(uri; localkw...)
    containers = parse(resp.body)
    for container in containers
        @info "Cleaning $(getid(container))"
        remove(container, force = true)
    end
    nothing
end
end # module
