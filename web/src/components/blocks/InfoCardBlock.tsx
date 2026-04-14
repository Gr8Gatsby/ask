import List from '@mui/material/List'
import ListItem from '@mui/material/ListItem'
import ListItemText from '@mui/material/ListItemText'
import Typography from '@mui/material/Typography'
import Divider from '@mui/material/Divider'
import type { InfoCardPayload } from '../../lib/types'
import { useTheme } from '../../lib/PlatformContext'

interface Props { payload: InfoCardPayload }

export default function InfoCardBlock({ payload }: Props) {
  const theme = useTheme()

  if (theme.isAndroid) {
    return (
      <div>
        <Typography variant="body1" sx={{ fontWeight: 500, mb: 1 }}>{payload.title}</Typography>
        <Divider />
        <List dense disablePadding>
          {payload.pairs.map((pair, i) => (
            <ListItem key={i} disableGutters sx={{ py: 0.5 }}>
              <ListItemText
                primary={pair.value}
                secondary={pair.key}
                slotProps={{
                  primary: { sx: { fontSize: '0.875rem', fontWeight: 500 } },
                  secondary: { sx: { fontSize: '0.75rem' } },
                }}
              />
            </ListItem>
          ))}
        </List>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      <p className="text-sm font-semibold text-ask-text">{payload.title}</p>
      <div className="border-t border-ask-sep pt-1.5 flex flex-col gap-1">
        {payload.pairs.map((pair, i) => (
          <div key={i} className="flex gap-3">
            <span className="text-xs text-ask-secondary w-20 flex-shrink-0">{pair.key}</span>
            <span className="text-xs text-ask-text font-medium">{pair.value}</span>
          </div>
        ))}
      </div>
    </div>
  )
}
