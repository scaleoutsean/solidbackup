@{
  Backends = @{
    prod = @{
      name         = "SF-PROD-192.168.1.30"
      mvip         = "192.168.1.30"
      username     = "admin"
      password     = "admin"
      }
  }
  Namespaces = @{
    projecta     = @{
      app1         = @{ 
        SrcId      = 398
        TgtId      = 401
        Part       = 0
        FsType     = "ext4"
        BkpType    = "image"
      }
    } 
    projectb     = @{ 
      web          = @{ 
        SrcId      = 399
        TgtId      = 402
        Part       = 0
        FsType     = "xfs"
        BkpType    = "image"
      }
      db           = @{
        SrcId      = 400
        TgtId      = 403
        Part       = 0 
        FsType     = "ext4"
        BkpType    = "file"
      }
    }
  }
}

