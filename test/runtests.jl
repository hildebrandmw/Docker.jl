using Docker
using Test

# Make sure "hildebrandmw/hello-world" is not in the local list of images. If
# so, remove it.
images = Docker.list_images()
test_image() = "hildebrandmw/hello-world:latest"

# Need to handle the case where there are no repo tags and `image["RepoTags"] === nothing`
function contains_test_image(image) 
    tag = image["RepoTags"]
    tag === nothing && return false
    return any(x -> occursin(test_image(), x), tag)
end

if any(contains_test_image, images)
    @info """
    Found local copy of the test repo: $(test_image())
    Removing for test validation
    """
    Docker.remove_image(test_image(); force = true)
end

getids(x) = Docker.getid.(x)
@testset "Testing Functions" begin
    Docker.pull_image(test_image())

    # Make sure that the image we just pulled show up in the list of images.
    images = Docker.list_images()
    @test any(contains_test_image, images) == true

    # Create a container based on this image.
    container = Docker.create_container(test_image())
    id = Docker.getid(container)
    @info "Created Container: $container"
    Docker.start(container)
    # Container should quite fairly quickly after running
    sleep(5) 

    # Get the expected response for the log.
    # Wrap the string returned by "get_log" in an IOBuffer and eachline to
    # avoid issues with newlines and carriage returns
    expected_log = eachline("log.txt")
    log = eachline(IOBuffer(Docker.log(container)))
    for (e,l) in zip(expected_log, log)
        @test e == l
    end

    # Test that the contain is in the list of containers
    containers = Docker.list_containers(all = true) 
    @test length(containers) > 0
    @test in(id, getids(containers))
    
    # Delete the container
    Docker.remove(container) 
    containers = Docker.list_containers(all = true)
    @test !in(id, getids(containers))

    # Remove the test image
    Docker.remove_image(test_image(); force = true) 
end
