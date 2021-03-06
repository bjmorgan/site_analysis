program defect_new

use atoms
use tetrahedra
use octahedra
use spheres
use cell
use input_parameters
 
implicit none

type species
    type (atom), dimension(:), allocatable :: ion
end type species  

type (input_parameter_set) :: params
type (species), dimension(:), allocatable :: spec
class (tetrahedron), dimension(:), allocatable :: tetra
class (octahedron), dimension(:), allocatable :: octa
class (spherical_site), dimension(:), allocatable :: sphera

character(len=30) :: inptfile, poly_out, atoms_out, npolyocc
integer :: i, j
integer :: nstep, thispoly
integer :: natomsout ! number of mobile atoms 
integer, allocatable, dimension(:) :: polylist, sitelist
character(len=30) :: fmtout, fmtout2
integer :: fin, fout1, fout2, fout3, fcell

interface

    function diagonal( square_matrix )
        double precision, dimension(:,:), intent(in) :: square_matrix
        double precision, dimension( size(square_matrix, 1) ) :: diagonal
    end function diagonal

end interface

inptfile  = 'defect_new.inpt'
poly_out  = 'sites_atoms.dat'
atoms_out = 'atoms_sites.dat'
npolyocc  = 'npolyocc.dat'

call params%read_from_file( inptfile )

allocate (spec(params%nspec))
do i=1, params%nspec
    allocate (spec(i)%ion(params%nsp(i)))
    forall (j=1:params%nsp(i)) spec(i)%ion(j)%id = j
enddo

if ( .not. params%variable_cell ) then
    boxlen = params%boxlen
    h = params%h
    halfboxlen = boxlen / 2.0
    cboxlen = diagonal( h ) * boxlen
    halfcboxlen = cboxlen / 2.0
endif

call setup_tet( tetra, params%ntet )
call setup_oct( octa, params%noct )
call setup_sph( sphera, params%nspheres )

natomsout = params%nsp( params%mobile_spec ) 

allocate( polylist( natomsout ) )
allocate( sitelist( params%ntet+params%noct+params%nspheres ) )
 
! read in ids for tetrahedra vertices
! TODO this should go in the tetrahedra.f90 file
if ( params%ntet > 0 ) then
    open(file=params%tetfile, status='old', newunit=fin)
    do i=1, params%ntet 
        read(fin,*) tetra(i)%vertex_ids
    enddo
    close(fin)
endif

! read in ids for octahedra vertices
! TODO this should go in the octahedra.f90 file
if ( params%noct > 0 ) then
    open(file=params%octfile, status='old', newunit=fin)
    do i=1, params%noct
        read(fin,*) octa(i)%vertex_ids
    enddo
    close(fin)
endif

! read in coordinates and radii for spherical sites
! TODO this should go in the spheres.f90 file
if ( params%nspheres > 0 ) then
    open(file=params%sphfile, status='old', newunit=fin)
    do i=1, params%nspheres
        read(fin,*) sphera(i)%centre, sphera(i)%cutoff
    enddo
    close(fin)
endif

open( file = params%posfile,   status='old', newunit=fin )
open( file = params%cellfile,  status='old', newunit=fcell )
open( file = npolyocc,  newunit=fout1 )
open( file = atoms_out, newunit=fout2 )
open( file = poly_out,  newunit=fout3 )

do concurrent (i=1:params%nspec)
    spec(i)%ion%polyid = 0
    spec(i)%ion%inoct = .false.
    spec(i)%ion%intet = .false.
    spec(i)%ion%insph = .false.
    spec(i)%ion%prev_intet = .false.
    spec(i)%ion%prev_inoct = .false.
    spec(i)%ion%prev_insph = .false.
end do

do nstep=1, params%nconfigs

    tetra%occnum = 0
    tetra%occupied = .false.
    octa%occnum = 0
    octa%occupied = .false.
    sphera%occnum = 0
    sphera%occupied = .false.
 
    do j=1, params%nsp( params%mobile_spec )
        associate( this_ion => spec(params%mobile_spec)%ion(j) )
            this_ion%previous_polyid = this_ion%polyid
            this_ion%prev_inoct = this_ion%inoct
            this_ion%prev_intet = this_ion%intet
            this_ion%prev_insph = this_ion%insph
            this_ion%polyid = 0
            this_ion%inoct = .false.
            this_ion%intet = .false.
            this_ion%insph = .false.
        end associate
    end do

    if ( params%variable_cell ) then
        read( fcell, * ) h(:,:) ! cell unit vectors are rows in h
        read( fcell, * ) boxlen(:) 
        halfboxlen = boxlen / 2.0
        cboxlen = diagonal( h ) * boxlen
        halfcboxlen = cboxlen / 2.0
    endif
 
    do i=1, params%nspec
        do j=1, params%nsp(i)
            associate( this_ion => spec(i)%ion(j) )
                read(fin,*) this_ion%r(1:3) 
                this_ion%r = move_inside_cell( this_ion%r ) ! apply periodic boundary conditions
            end associate
        enddo
    enddo
  
    do thispoly = 1, params%ntet ! construct tetrahedra
        call tetra(thispoly)%set_vertices_from_ids( spec( params%lattice_spec )%ion )
        call tetra(thispoly)%enforce_pbc
        call tetra(thispoly)%assign_faces
    end do

    do thispoly = 1, params%noct ! construct octahedra
        call octa(thispoly)%set_vertices_from_ids( spec( params%lattice_spec )%ion )
        call octa(thispoly)%enforce_pbc
        call octa(thispoly)%assign_faces
    end do

    ionloop: do j=1, params%nsp( params%mobile_spec )
        associate( this_ion => spec( params%mobile_spec )%ion(j) )
            ! test whether ions are in the same polyhedra as the previous step
            if ( this_ion%prev_intet ) then
                call tetra( this_ion%previous_polyid )%occupied_by( this_ion )
            else if ( this_ion%prev_inoct ) then
                call octa( this_ion%previous_polyid )%occupied_by( this_ion )
            else if ( this_ion%prev_insph ) then
                call sphera( this_ion%previous_polyid )%occupied_by( this_ion )
            end if
            if ( this_ion%intet .or. this_ion%inoct .or. this_ion%insph ) cycle ionloop
            ! ion has moved. search over remaining tetrahedra
            tetloop: do thispoly = 1, params%ntet
                if ( this_ion%prev_intet .and. thispoly .eq. this_ion%previous_polyid ) cycle tetloop
                call tetra( thispoly )%occupied_by( this_ion )
                if ( this_ion%intet ) cycle ionloop
            end do tetloop
            ! search over remaining octahedra
            octloop: do thispoly = 1, params%noct
                if ( this_ion%prev_inoct .and. thispoly .eq. this_ion%previous_polyid ) cycle octloop
                call octa( thispoly )%occupied_by( this_ion )
                if ( this_ion%inoct ) cycle ionloop
            end do octloop
            ! search over spherical sites
            sphloop: do thispoly = 1, params%nspheres
                if ( this_ion%prev_insph .and. thispoly .eq. this_ion%previous_polyid ) cycle sphloop
                call sphera( thispoly )%occupied_by( this_ion )
                if ( this_ion%insph ) cycle ionloop
            end do sphloop
   
            ! if we reach here without cycling ionloop, this ion has not been located in any polyhedron
            !write(6,*) 'Ion ', j,' not in any polyhedra, at ', this_ion%r
        end associate
    end do ionloop

    write(6,*) "step ", nstep, count(tetra%occupied), count(octa%occupied), count(sphera%occupied)
    write(fout1,*) nstep, count(tetra%occupied), count(octa%occupied), count(sphera%occupied)

    natomsout = 0
    polylist = 0
    do j=1, params%nsp( params%mobile_spec )
        associate( this_ion => spec(params%mobile_spec)%ion(j) )
            natomsout = natomsout + 1
            if ( this_ion%inoct ) then
                polylist(natomsout) = octa( this_ion%polyid )%unique_id()
            else if ( this_ion%intet ) then
                polylist(natomsout) = tetra( this_ion%polyid )%unique_id()
            else if (this_ion%insph )then
                polylist(natomsout) = sphera( this_ion%polyid )%unique_id()
            else
                polylist(natomsout) = 0
            endif
        end associate
    enddo

    sitelist( 1:params%ntet ) = tetra%occnum
    sitelist( params%ntet+1:params%ntet+params%noct ) = octa%occnum
    sitelist( params%ntet+params%noct+1:params%ntet+params%noct+params%nspheres ) = sphera%occnum

    write( fmtout,  '(A4,I5,A7)') "(I5,", natomsout, "(I6,X))" ! internal write to define output formatting
    write( fmtout2, '(A4,I5,A7)') "(I5,", params%ntet+params%noct+params%nspheres, "(I6,X))" ! internal write to define output formatting
    write( fout2, fmtout )  nstep, polylist(:)
    write( fout3, fmtout2 ) nstep, sitelist(:)

enddo !ends loop over nconfig steps

close( fin )
close( fout1 )
close( fout2 )
close( fout3 )

stop

end program defect_new

function diagonal( square_matrix )
    implicit none
    double precision, dimension(:,:), intent(in) :: square_matrix
    double precision, dimension(size(square_matrix)) :: temp_array
    double precision, dimension(size(square_matrix, 1)) :: diagonal
    temp_array = pack( square_matrix, .true. )
    diagonal = temp_array( 1::size(diagonal) + 1 )
end function diagonal
