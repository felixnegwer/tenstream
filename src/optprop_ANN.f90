module m_optprop_ANN
  USE m_data_parameters, ONLY : ireals, iintegers, zero,one,i1
  use m_arrayio

  implicit none
  private
  public ANN_init,ANN_get_dir2dir,ANN_get_dir2diff,ANN_get_diff2diff

  logical,parameter :: ldebug=.True.,check_input=.True.

  type ANN
    real(ireals),allocatable,dimension(:) :: weights, units
    integer(iintegers),allocatable,dimension(:) :: inno, outno
    real(ireals),allocatable,dimension(:,:) :: eni, deo, inlimits
    integer(iintegers),allocatable,dimension(:,:) :: conec
    real(ireals),allocatable,dimension(:) :: lastcall,lastresult
    integer(iintegers) :: in_size=-1, out_size=-1
    logical :: initialized=.False.
  end type

  type(ANN),save :: diff2diff_network, dir2dir_network, dir2diff_network, direct_network

contains

  subroutine ANN_init(dx,dy)
      real(ireals),intent(in) :: dx,dy
      character(300),parameter :: fname='/usr/users/jakub/cosmodata/tenstream/ANN/LUT2ANN.h5'
      character(300) :: netname
      integer(iintegers) :: ierr

!      integer(iintegers) :: phi,theta,iphi,itheta

      if(dx.ne.dy) then
        print *,'dx ne dy,  we probably dont have a network for asymmetric grid sizes!.... exiting....'
        call exit()
      endif

      write(netname, FMT='("net_",I0,"/dir2diff")' ) nint(dx/10)*10
      call loadnet(fname, netname, dir2diff_network, ierr)

      write(netname, FMT='("net_",I0,"/dir2dir")' ) nint(dx/10)*10
      call loadnet(fname, netname, dir2dir_network, ierr)

      write(netname, FMT='("net_",I0,"/diffuse")' ) nint(dx/10)*10
      call loadnet(fname, netname, diff2diff_network, ierr)

      !            write(netname, FMT='("net_I0/direct")' ) nint(dx/10)*10
      !            call loadnet(fname, netname, direct_network, ierr)
  end subroutine

  subroutine loadnet(fname, netname,net,ierr)
      character(300) :: fname, netname
      type(ANN) :: net
      integer(iintegers),intent(out) :: ierr
      integer(iintegers) :: errcnt,k
      ierr=0
      if(.not.allocated(net%weights)) then
        call h5load([fname,netname,'weights' ],net%weights ,ierr) ; errcnt = ierr         ! ; print *,'loading weights ',ierr
        call h5load([fname,netname,'units'   ],net%units   ,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading units   ',ierr
        call h5load([fname,netname,'inno'    ],net%inno    ,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading inno    ',ierr
        call h5load([fname,netname,'outno'   ],net%outno   ,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading outno   ',ierr
        call h5load([fname,netname,'conec'   ],net%conec   ,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading conec   ',ierr
        call h5load([fname,netname,'deo'     ],net%deo     ,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading deo     ',ierr
        call h5load([fname,netname,'eni'     ],net%eni     ,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading eni     ',ierr
        call h5load([fname,netname,'inlimits'],net%inlimits,ierr) ; errcnt = errcnt+ierr  ! ; print *,'loading inlimits',ierr
        if(ldebug) print *,'Loading ANN from:',fname,'name of Network: ',trim(netname),' resulted in errcnt',errcnt
        if(errcnt.ne.0) return

        net%in_size = size(net%inno)
        net%out_size= size(net%outno)

        if(ldebug) then
          print *,'shape eni',shape(net%eni),'weights',shape(net%weights),'conec',shape(net%conec)
          do k=1,ubound(net%inlimits,1)
            print *,'input limits(',k,')',net%inlimits(k,:),'eni',net%eni(k,:)
          enddo
        endif

        allocate(net%lastcall(net%in_size) ) ; net%lastcall=-1
        allocate(net%lastresult(net%out_size) )

        net%initialized = .True.
      endif

  end subroutine

  subroutine ANN_get_dir2dir(dz, kabs, ksca, g, phi, theta, C)
      real(ireals),intent(in) :: dz,kabs,ksca,g,phi,theta
      real(ireals),intent(out) :: C(:)

      integer(iintegers) :: ierr

      call calc_net(C, [dz,kabs,ksca,g,phi,theta] , dir2dir_network,ierr )
      if(ierr.ne.0) then
        print *,'Error when calculating dir2dir_net coeffs',ierr
        call exit()
      endif

      C = min(one, max(C,zero) )
  end subroutine

  subroutine ANN_get_dir2diff(dz, kabs, ksca, g, phi, theta, C)
      real(ireals),intent(in) :: dz,kabs,ksca,g,phi,theta
      real(ireals),intent(out) :: C(:)

      integer(iintegers) :: ierr

      call calc_net(C, [dz,kabs,ksca,g,phi,theta] , dir2diff_network,ierr )
      if(ierr.ne.0) then
        print *,'Error when calculating dir2diff_net coeffs',ierr
        call exit()
      endif

      C = min(one, max(C,zero) )
  end subroutine

  subroutine ANN_get_diff2diff(dz, kabs, ksca, g, C)
      real(ireals),allocatable :: C(:)
      real(ireals),intent(in) :: dz,kabs,ksca,g
      integer(iintegers) :: ierr

      if(.not.diff2diff_network%initialized) then
        print *,'network that is about to be used for coeffs is not loaded! diffuse:'
        call exit()
      endif
      allocate(C(diff2diff_network%out_size) )

      call calc_net(C, [dz,kabs,ksca,g],diff2diff_network,ierr )
      if(ierr.ne.0) then
        print *,'Error when calculating diff_net coeffs',ierr
        call exit()
      endif

      C = min(one, max(C,zero) )
  end subroutine

  subroutine calc_net(coeffs,inp,net,ierr)
      type(ANN),intent(inout) :: net
      real(ireals),intent(out):: coeffs(net%out_size )
      real(ireals),intent(in) :: inp(:)
      integer(iintegers),intent(out) :: ierr

      real(ireals) :: input(net%in_size)

      integer(iintegers) :: k,srcnode,trgnode,ctrg,xn

      ierr=0

      input = inp

      if(all(approx(net%lastcall,inp) )) then
        coeffs = net%lastresult
        return
      endif

      !        input([1,2]) = log(input([1,2]))
      !        input([4,5]) = log(input([4,5]))
      !        input(   7 ) = input(   7 ) *100._ireals

      ! Concerning the lower limits for optprops, just take the ANN limits. Theres not happening much anyway.
      input(1) = max(net%inlimits(1,1),input(1))
      input(2) = max(net%inlimits(2,1),input(2))
      input(4) = max(net%inlimits(4,1),input(4))

!      if(net%in_size.ge.5) then ! we should not fudge solar angles... this might confuse users...
!        input(5) = max(net%inlimits(5,1),input(5))
!        input(6) = max(net%inlimits(6,1),input(6))
!      endif

      ! Concerning the upper limits for optprops, take the ANN limits. This is huge TODO, as this might lead to super wrong results! This is a very dirty hack for the time being!
      !        input(1) = min(net%inlimits(1,2),input(1))
      !        input(2) = min(net%inlimits(2,2),input(2))
      !        input(4) = min(net%inlimits(4,2),input(4))
      !        input(5) = min(net%inlimits(5,2),input(5))

      ! for asymmetry parameter, this is odd, that the cosmo ANN input doesnt capture it.
      ! this should not happen for a real run but if this is a artificial case, it very well may be.
      ! TODO: make sure, this doesnt happen.
      !        input(3) = max( net%inlimits(3,1), min( net%inlimits(3,2), input(3) ))
      !        input(6) = max( net%inlimits(6,1), min( net%inlimits(6,2), input(6) ))

      !{{{ check input
      !       print *,'This is function: ANN_get_direct_Transmission'
      if(check_input) then
        if(inp(1).lt.net%inlimits(1,1).or.inp(1).gt.net%inlimits(1,2)) then
          print *,'dz out of ANN range',inp(1),'limits:',net%inlimits(1,:)        ;ierr=1;! call exit()
        endif
        if(input(2).lt.net%inlimits(2,1).or.input(2).gt.net%inlimits(2,2)) then
          print *,'kabs out of ANN range',input(2),'limits:',net%inlimits(2,:) ;ierr=2;! call exit()
        endif
        if(input(3).lt.net%inlimits(3,1).or.input(3).gt.net%inlimits(3,2)) then
          print *,'ksca out of ANN range',input(3),'limits:',net%inlimits(3,:)    ;ierr=3;! call exit()
        endif
        if(input(4).lt.net%inlimits(4,1).or.input(4).gt.net%inlimits(4,2)) then
          print *,'g out of ANN range',input(4),'limits:',net%inlimits(4,:) ;ierr=4;! call exit()
        endif
        if(net%in_size.ge.5) then
          if(input(5).lt.net%inlimits(5,1).or.input(5).gt.net%inlimits(5,2)) then
            print *,'phi out of ANN range',input(5),'limits:',net%inlimits(5,:) ;ierr=5;! call exit()
          endif
          if(input(6).lt.net%inlimits(6,1).or.input(6).gt.net%inlimits(6,2)) then
            print *,'theta out of ANN range',input(6),'limits:',net%inlimits(6,:)    ;ierr=6;! call exit()
          endif
        endif
      endif
      !}}}

      ! normalize input
      do k=1,ubound(net%inno,1)
        net%units(net%inno(k)) = net%eni(k,1) * input(k) + net%eni(k,2)
      enddo

      ! Propagate signal through conecs
      ctrg = net%conec(1,2)
      net%units(ctrg) = 0._ireals
      do xn=1,ubound(net%weights,1)
        srcnode = net%conec(xn,1)
        trgnode = net%conec(xn,2)
        !if next unit
        if (trgnode.ne.ctrg) then
          net%units(ctrg) = 1._ireals/(1._ireals+exp(-net%units(ctrg)))
          ctrg = trgnode
          if (srcnode.eq.0) then !handle bias
            net%units(ctrg) = net%weights(xn)
          else
            net%units(ctrg) = net%units(srcnode) * net%weights(xn)
          endif
        else
          if (srcnode.eq.0) then !handle bias
            net%units(ctrg) = net%units(ctrg) + net%weights(xn)
          else
            net%units(ctrg) = net%units(ctrg) + net%units(srcnode) * net%weights(xn)
          endif
        endif
      enddo
      net%units(ctrg) = 1._ireals/(1._ireals+exp(-net%units(ctrg))) !for last unit

      ! Denormalize output
      do k=1,ubound(net%outno,1)
        coeffs(k) = net%deo(k,1) * net%units(net%outno(k)) + net%deo(k,2)
      enddo

      net%lastcall = input
      net%lastresult = coeffs(:)
    contains 
      pure elemental logical function approx(a,b)
        real(ireals),intent(in) :: a,b
        real(ireals),parameter :: eps=1e-5
        if( a.le.b+eps .and. a.ge.b-eps ) then
          approx = .True.
        else
          approx = .False.
        endif
    end function

end subroutine

end module