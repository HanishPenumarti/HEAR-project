/*
 * Control experiment for HEAR's pipelining (our addition, not part of libhear).
 *
 * libhear's pipelined MPI_Allreduce splits a message into blocks of
 * HEAR_PIPELINING_BLOCK_SIZE elements and runs each block as
 * PMPI_Iallreduce + PMPI_Wait, with encryption/decryption in between.
 * This library makes exactly the same collective calls, block by block,
 * but encrypts nothing. Comparing HEAR with it at the same block size
 * separates the cost of encryption from the effect of chunking itself.
 *
 * Build: mpicc -O3 -fPIC -shared -o libchunk.so chunk.c
 * Use:   mpirun -genv LD_PRELOAD libchunk.so -genv CHUNK_BLOCK_SIZE <elements> ...
 */
#include <mpi.h>
#include <stdlib.h>

static int block_size = 65536;   /* libhear's default, in elements */
static int initialised = 0;

int MPI_Allreduce(const void *sendbuf, void *recvbuf, int count,
                  MPI_Datatype datatype, MPI_Op op, MPI_Comm comm)
{
    if (!initialised) {
        const char *env = getenv("CHUNK_BLOCK_SIZE");
        if (env && atoi(env) > 0)
            block_size = atoi(env);
        initialised = 1;
    }
    int type_size, ret = MPI_SUCCESS;
    PMPI_Type_size(datatype, &type_size);

    for (int offset = 0; offset < count; offset += block_size) {
        int n = count - offset < block_size ? count - offset : block_size;
        size_t byte_off = (size_t)offset * (size_t)type_size;
        const void *s = (sendbuf == MPI_IN_PLACE) ? MPI_IN_PLACE
                                                  : (const char *)sendbuf + byte_off;
        MPI_Request req;
        ret = PMPI_Iallreduce(s, (char *)recvbuf + byte_off, n, datatype, op, comm, &req);
        if (ret != MPI_SUCCESS)
            return ret;
        ret = PMPI_Wait(&req, MPI_STATUS_IGNORE);
        if (ret != MPI_SUCCESS)
            return ret;
    }
    return ret;
}
