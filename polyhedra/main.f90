program find_polyhedra

use atoms
use cell
use octahedra
use tetrahedra

implicit none

type (atom), dimension(:), allocatable :: part
type (octahedron), dimension(:), allocatable :: octa
type (tetrahedron), dimension(:), allocatable :: tetra
character(len=20) :: posfile, inptfile
integer :: natoms, i, j, k, l, m, n, v, fout, dotprod, temp
integer :: fin
integer, dimension(:), allocatable :: v_mask, v_index
integer, dimension(6) :: v_list
type(atom), dimension(6) :: p_list
double precision, dimension(2) :: rcut, rcutsq ! minimum, maximum
double precision :: rij(3), rij_direct(3), rijsq
logical, dimension(:), allocatable :: pair_list
integer, dimension(1) :: opp_ion
double precision, dimension(:), allocatable :: rijsq_store
integer, dimension(13) :: nearest_neighbours
logical :: close_packed_lattice
integer :: ntet_max, noct_max
type(atom), dimension(4) :: equatorial_vertices

interface

    function diagonal( square_matrix )
        double precision, dimension(:,:), intent(in) :: square_matrix
        double precision, dimension( size(square_matrix, 1) ) :: diagonal
    end function diagonal

    pure function ortho_pbc( r, boxlen )
        double precision, dimension(3), intent(in) :: r, boxlen
        double precision, dimension(3) :: ortho_pbc
    end function ortho_pbc

    subroutine read_input( inptfile, posfile, natoms, cboxlen, rcut, h, close_packed_lattice, cpplane )
        double precision, dimension(3), intent(out) :: cboxlen, cpplane
        character(len=20), intent(out) :: posfile
        character(len=*), intent(in) :: inptfile
        integer, intent(out) :: natoms
        double precision, dimension(2), intent(out) :: rcut
        double precision, intent(out) :: h(3,3)
        logical, intent(out) :: close_packed_lattice
    end subroutine read_input

    subroutine swap( x, i, j )
        integer, dimension(:), intent(inout) :: x
        integer, intent(in) :: i, j
    end subroutine swap

    function minimum_locations_from_array( array, number_of_values )    
        double precision, dimension(:), intent(in) :: array
        integer, intent(in) :: number_of_values
        integer, dimension( number_of_values ) :: minimum_locations_from_array
    end function minimum_locations_from_array

end interface

inptfile = "polyhedra.inpt"
call read_input( inptfile, posfile, natoms, cboxlen, rcut, h, close_packed_lattice, cpplane )

rcutsq = rcut * rcut
boxlen = cboxlen * diagonal(h)
halfboxlen = boxlen/2
halfcboxlen = boxlen/2 !warning. Should this be cboxlen/2?

noct_max = natoms
ntet_max = natoms*2

allocate( part(natoms) )
allocate( octa( noct_max ) )
allocate( tetra( ntet_max ) ) 
allocate( pair_list(natoms), v_mask(natoms), v_index(natoms) )
allocate( rijsq_store( natoms ) )

open(file=posfile, status='old', form='formatted', newunit=fin)
do i=1, natoms
    allocate (part(i)%neigh(natoms))
    read(fin,*) part(i)%r(1:3)
end do

forall (i=1:natoms) 
    part(i)%neigh(:) = .false.
    part(i)%id = i
    ! map to an orthorhombic cell, assuming rhombohedral input
    part(i)%r = ortho_pbc(part(i)%r, boxlen) 
end forall

forall (i=1:natoms) v_index(i) = i

write( 6,* ) 'Creating neighbour lists'
! create neighbour list
! assuming the input file is in lab coordinates
do i=1, natoms
    do j=1, natoms
        rij_direct = dr( part(i)%r, part(j)%r )
        rij = r_as_minimum_image( rij_direct )
        rijsq_store(j) = sum( rij * rij )
    end do
    if (close_packed_lattice) then
! for a close-packed lattice, each ion has 13 nearest neighbours 
! (including itself)
        nearest_neighbours = minimum_locations_from_array( rijsq_store, 13 )
        do j=1, size(nearest_neighbours)
            part(i)%neigh( nearest_neighbours(j) ) = .true.
        end do
    else
! if the lattice is *not* close-packed, we use rcut(min, max) to define
! neighbour lists
        part(i)%neigh = ( rijsq_store <= rcutsq(2) )
    end if
end do

forall (i=1:natoms) part(i)%nneigh = count(part(i)%neigh(:))

! All neighbour lists now have 13 true entries
! since the previous section finds the 13 closest ions
! Not sure what happens now if the system is *not* close-packed !!

do i=1, natoms
    call part(i)%set_neighbour_ids
end do

write(6,*) 'searching for tetrahedra'
!find tetrahedra
!tetrahedra are defined by sets of four atoms, where any triplet are neighbours of the fourth
do i=1, natoms-3   
    do j=i+1, natoms-2
        if ( .not.part(j)%neigh(i) )cycle
        do k=j+1, natoms-1
            if ( .not. ( part(k)%neigh(j) .and. part(k)%neigh(i) ) ) cycle
            do l=k+1, natoms
                if ( .not. ( part(l)%neigh(k) .and. part(l)%neigh(j) .and. part(l)%neigh(i) ) ) cycle
                pair_list = .false.
                pair_list(i) = .true.
                pair_list(j) = .true.
                pair_list(k) = .true.
                pair_list(l) = .true.
                ntet = ntet + 1
                if ( ntet > ntet_max ) then
                    stop( 'Found too many tetrahedra. Maybe decrease the cutoff?')
                end if
                associate( tet => tetra(ntet) )
                    call tet%init
                    call tet%set_vertices( pack(part, pair_list) )
                end associate
            end do
        end do
    end do
end do

write(6,*) 'searching for octahedra'
! find octahedra, list of ions are arranged in pairs of opposite vertices (1,2)(3,4)(5,6)
do i=1, natoms-1 
    do j=i+1, natoms
        if ( part(i)%neigh(j) ) cycle
        pair_list = ( part(i)%neigh .and. part(j)%neigh )
        if (count(pair_list) == 4) then
            v_list(1) = i
            v_list(2) = j
            v_list(3:6) = pack( v_index, pair_list )
            opp_ion = pack( (/4,5,6/) ,.not.part( v_list(3) )%neigh( v_list(4:6) ) )
            if ( all( (/4,5,6/) .ne. opp_ion(1) ) ) then ! octahedron is probably constructed from four face-sharing tetrahedra
                write(6,*) "Opposing vertices in this octahedron are too close"
                write(6,*) "Ions: ", v_list
                stop
            end if
            call swap(v_list, 4, opp_ion(1))
            ! test that all points are topologically equivalent (if not, assume
            ! we have a false positive identification)
            if (     count( part(v_list(3))%neigh(v_list) .and. part(v_list(4))%neigh(v_list) ) /= 4 &
                .or. count( part(v_list(5))%neigh(v_list) .and. part(v_list(6))%neigh(v_list) ) /= 4 ) cycle 
            if ( .not. oct_exists( v_list, octa( 1:noct ) ) ) then
                noct = noct + 1
                if ( noct > noct_max ) then
                    stop( 'Found too many octahedra. Maybe decrease the cutoff?' )
                end if
                associate( oct => octa(noct) )
                    call oct%init
                    p_list = part( v_list )
                    call oct%set_vertices( p_list )
                end associate
            end if
        end if
    end do
end do

write(6,*) ntet, 'tetrahedra found'
write(6,*) noct, 'octahedra found'

do i=1, ntet
    call tetra(i)%enforce_pbc
end do

do i=1, noct
    call octa(i)%enforce_pbc
end do

do i=1, ntet
    tetra(i)%orientation = 0
    do j=1, 4
        temp = -int( sign( 1.0,sum( (tetra(i)%vertex(j)%r-tetra(i)%centre)*cpplane ) ) )
        tetra(i)%orientation = tetra(i)%orientation + temp
    end do
    tetra(i)%orientation = sign(1,tetra(i)%orientation)
end do

call write_output( tetra(1:ntet), octa(1:noct) )

contains

subroutine write_output( tetra, octa )

    use octahedra
    use tetrahedra

    implicit none

    type(tetrahedron), dimension(:), intent(in) :: tetra
    type(octahedron), dimension(:), intent(in) :: octa
    integer :: ntet_up = 0, ntet_down = 0
    integer :: ftet1_cent, ftet2_cent, foct_cent, ftet1, ftet2, foct
    integer i

    open(file='tet1_c.out', newunit=ftet1_cent, form='formatted')
    open(file='tet2_c.out', newunit=ftet2_cent, form='formatted')
    open(file='oct_c.out', newunit=foct_cent, form='formatted')
    open(file='tet1.list', newunit=ftet1, form='formatted')
    open(file='tet2.list', newunit=ftet2, form='formatted')
    open(file='oct.list', newunit=foct, form='formatted')

    do i=1, size(tetra)    
        if (tetra(i)%orientation == 1) then
            ntet_up = ntet_up + 1
            write(ftet1,*) tetra(i)%vertex%id
            write(ftet1_cent,*) tetra(i)%centre
        else
            ntet_down = ntet_down + 1
            write(ftet2,*) tetra(i)%vertex%id
            write(ftet2_cent,*) tetra(i)%centre
        end if
    end do

    write(6,*) size( octa )
    do i=1, size(octa)
        write(foct,*) octa(i)%vertex%id
        write(foct_cent,*) octa(i)%centre
    end do

    close(ftet1_cent)
    close(ftet2_cent)
    close(foct_cent)
    close(ftet1)
    close(ftet2)
    close(foct)

    write(6,*) ntet_up,'tet1',ntet_down,'tet2',noct,'oct'

end subroutine write_output
    
end program find_polyhedra

subroutine read_input( inptfile, posfile, natoms, cboxlen, rcut, h, close_packed_lattice, cpplane )
    implicit none
    double precision, dimension(3), intent(out) :: cboxlen, cpplane
    character(len=20), intent(out) :: posfile
    character(len=*), intent(in) :: inptfile
    integer, intent(out) :: natoms
    double precision, dimension(2), intent(out) :: rcut
    double precision, intent(out) :: h(3,3)
    logical, intent(out) :: close_packed_lattice
    integer :: fin

    open(file=inptfile, status='old', form='formatted', newunit=fin)
        read(fin,*) posfile
        read(fin,*) natoms
        read(fin,*) cboxlen(1:3)
        read(fin,*) h(1:3,1:3)
        read(fin,*) close_packed_lattice
        if (close_packed_lattice) then
            read(fin,*) cpplane(1:3)
        else
            read(fin,*) rcut
            if ( rcut(2) < rcut(1) ) stop( "Check rcut values!" )
        endif
    close(fin)
end subroutine read_input
 
function diagonal( square_matrix )
    implicit none
    double precision, dimension(:,:), intent(in) :: square_matrix
    double precision, dimension(size(square_matrix)) :: temp_array
    double precision, dimension(size(square_matrix, 1)) :: diagonal
    temp_array = pack(square_matrix, .true.)
    diagonal = temp_array(1::size(diagonal)+1)
end function diagonal

pure function ortho_pbc( r, boxlen )
    implicit none
    double precision, dimension(3), intent(in) :: r
    double precision, dimension(3), intent(in) :: boxlen
    double precision, dimension(3) :: ortho_pbc
    integer :: i
    forall(i=1:3) ortho_pbc(i) = r(i) - (int(r(i)/boxlen(i)) * boxlen(i)) ! map to orthorhombic cell
end function ortho_pbc

subroutine swap(x, i, j)
    implicit none
    integer, dimension(:), intent(inout) :: x
    integer, intent(in) :: i, j
    integer :: temp
    temp = x(i)
    x(i) = x(j)
    x(j) = temp
end subroutine swap

function minimum_locations_from_array( array, number_of_values )
    implicit none
    double precision, dimension(:), intent(in) :: array
    integer, intent(in) :: number_of_values
    logical, dimension( size(array) ) :: mask
    integer, dimension( number_of_values ) :: minimum_locations_from_array
    integer :: i

    minimum_locations_from_array = 0
    mask = .true.

    do i=1, number_of_values
        minimum_locations_from_array(i) = minloc(array, 1, mask )
        mask( minloc( array, 1, mask ) ) = .false.
    end do    
end function minimum_locations_from_array

